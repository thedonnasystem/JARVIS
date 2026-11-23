# Creative Studio: self-hosted generation (provider `comfyui-selfhost`)

Goal: realistic UGC (AI-model agency, Klumbsy, Donna's marketing, other brands) at about $0 until there is revenue.

Two facts set the design:
- Open-Higgsfield-AI is only a front-end for the paid Muapi.ai API.
- fal.ai is paid per call.

So the studio gets its own GPU worker: ComfyUI plus open-weight models, on a free Kaggle GPU first, then an owned card or an owner-rented pod.

Prices and speeds below were checked on 2026-11-23. Every speed and every cost per output is an **ESTIMATE** until the worker's `--selftest` has
measured it on the real GPU.

## How it fits

| Piece | Where |
|---|---|
| Adapter, content rules, persona packs, batch queue, $0 meter, CLI (`python3 hq_creative_selfhost.py status / enqueue / drain`) | `hq_creative_selfhost.py` |
| Router hooks: the selfhost branch in `adapters_for`; fal.ai only as an opt-in fallback; the `fits` / `preference` tie-break in `candidates`; the content rules on every job; persona + script into the spec; worker meta into the asset meta | `hq_creative_studio.py` (small edits) |
| Extra workflows (Z-Image Turbo, Z-Image + LoRA, Wan 2.2 S2V), VRAM floors, weight files with licences, GPU profiles | `creative_studio/selfhost/manifest.json`, `creative_studio/selfhost/workflows/` |
| Reused M8c workflows (FLUX.1 schnell, Wan 2.2 TI2V-5B and T2V-A14B; LTX-Video only behind `CREATIVE_LTX_LICENCE_OK=1`) | `creative_studio/comfyui/` |
| GPU worker: install, models, token proxy, Kokoro TTS, tunnel, self-stop, selftest, batch mode | `creative_studio/selfhost/worker/fz_worker.py` |
| Kaggle notebook (tunnel), Colab notebook (batch, no tunnel), RunPod / Vast.ai template | `creative_studio/selfhost/worker/` |
| Provider row (OFF, 0 cents, unit `job`) | `migrations/20261209_creative_selfhost_v1.sql` |
| Persona pack example (a fictional adult) | `creative_studio/selfhost/personas/nova-example.json` |
| Tests (fake worker, no GPU, no network) | `test_hq_creative_selfhost.py` |

**Request path.**
1. Jarvis submits a job (`creative_submit`) and adds it to the batch queue.
2. When the worker answers `GET /system_stats`, `drain` runs the waiting jobs, grouped by module (image, voice, video, ugc) so the weights stay loaded.
3. The router picks `comfyui-selfhost` because it costs 0. Within it, the order is:
   - images: Z-Image Turbo, then FLUX.1 schnell;
   - ugc: Wan S2V talking head (when there is a reference image), then Wan 5B, then A14B.
   - A QA failure escalates to the next model.
4. The adapter:
   - checks the content rules and the persona;
   - checks every node and input against the worker's `/object_info`, so a wrong graph costs no GPU time;
   - uploads the reference image and voice;
   - submits to `/prompt`, polls `/history`, and downloads the result from `/view`.

**Money.**
- Selfhost attempts are 0 cents, so `run_job` never reserves for them.
- When the row is enabled and `COMFYUI_SELFHOST_URL` / `COMFYUI_SELFHOST_TOKEN` are set, fal.ai is removed from the router unless `CREATIVE_FAL_FALLBACK=1`.
- If the worker is down, jobs keep waiting. They never fall through to paid calls without that flag.
- The fal.ai caps, spend gate and premium rules are unchanged.
- The meter counts GPU-seconds. With `COMFYUI_SELFHOST_HOURLY_USD` set (a rented pod), it also shows what that time was worth. That is paid to the pod provider outside the studio.

**Security.**
- The worker's ComfyUI listens on 127.0.0.1 only.
- Port 8189 is a proxy that:
  - requires `Authorization: Bearer <token>`, checked in constant time;
  - forwards only the API routes the studio uses, plus `/fz/tts` and `/fz/health`;
  - caps request bodies at 60 MB.
- Jarvis talks to it only through `hq_hands_adapters.http`: https only, no redirects.
- The token is never logged. Keep the Kaggle notebook private, because its printout is the key.

## Models chosen (licences checked on the Hugging Face model cards, 2026-11-23)

| Use | Model | Licence | Why | Runs on |
|---|---|---|---|---|
| Image (default) | **Z-Image Turbo** (Tongyi-MAI, 6B, 9 steps) | Apache-2.0 ([model card](https://huggingface.co/Tongyi-MAI/Z-Image-Turbo)) | Best photoreal quality per GPU-second of the commercially usable models; fits 16 GB | T4 and up |
| Image (fallback) | FLUX.1 schnell | Apache-2.0 ([card](https://huggingface.co/black-forest-labs/FLUX.1-schnell)) | Already in M8c; 4 steps | T4 and up |
| Image, persona consistency | Z-Image Turbo + the persona's LoRA (train with ai-toolkit on a rented GPU, about 1 h) | Apache-2.0 base; the LoRA is ours | Same face in every post | T4 and up |
| Video (default) | **Wan 2.2 TI2V-5B** | Apache-2.0 ([card](https://huggingface.co/Wan-AI/Wan2.2-TI2V-5B)) | 720p@24fps on one consumer GPU: "under 9 minutes" per 5 s clip on a 4090 (model card) | T4 (480p) and up |
| Video (quality) | Wan 2.2 T2V-A14B | Apache-2.0 ([card](https://huggingface.co/Wan-AI/Wan2.2-T2V-A14B)) | Escalation after a QA failure | 24 GB and up (48 GB recommended) |
| Talking head / lip-sync UGC | **Wan 2.2 S2V-14B** (native ComfyUI nodes) | Apache-2.0 ([card](https://huggingface.co/Wan-AI/Wan2.2-S2V-14B)) | Image + voice to a talking video in one model, no custom nodes | 24 GB (fp8) and up |
| TTS / voice | **Kokoro-82M** (stock voices) | Apache-2.0 ([card](https://huggingface.co/hexgrad/Kokoro-82M)) | Tiny and fast, good English | Any (CPU is fine) |
| Captions | faster-whisper (M8c `creative_studio/tools/whisper_words.py`) | MIT ([Systran weights](https://huggingface.co/Systran/faster-whisper-large-v3)) | Word timings for burned captions | Jarvis host CPU |

**Considered and not routed (yet):**
- InfiniteTalk (MeiGen-AI): Apache-2.0 ([card](https://huggingface.co/MeiGen-AI/InfiniteTalk)). Long-form lip-sync. It needs the WanVideoWrapper custom node; next step if S2V's 5 s chunks are too short.
- LatentSync 1.6 (ByteDance): **OpenRAIL++** ([card](https://huggingface.co/ByteDance/LatentSync-1.6)). Commercial use is allowed, with use restrictions. Lip-sync onto existing video.
- Chatterbox (Resemble AI): MIT ([card](https://huggingface.co/ResembleAI/chatterbox)). Expressive TTS with voice cloning. It is left out because cloning is a real-person-likeness risk; add it only with a stock or consented voice.
- Qwen-Image / Qwen-Image-2512 and Qwen-Image-Edit-2509/2511: Apache-2.0 ([card](https://huggingface.co/Qwen/Qwen-Image-Edit-2509)). Strong reference-image persona editing. They are 20B (about 20 GB in fp8), so they are a 48 GB-profile addition.
- FLUX.2 [klein] 4B: Apache-2.0 ([card](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B)). A viable small image alternative.
- Wan 2.2 Lightning 4-step LoRAs (lightx2v): Apache-2.0 ([card](https://huggingface.co/lightx2v/Wan2.2-Lightning)). About 5x fewer steps for A14B. Add them after the selftest proves the base graph.

**Excluded:**
- FLUX.1 [dev]: non-commercial licence ([card](https://huggingface.co/black-forest-labs/FLUX.1-dev)).
- F5-TTS: CC-BY-NC-4.0 weights ([card](https://huggingface.co/SWivid/F5-TTS)).
- InstantID / PuLID: they depend on InsightFace face models, which are licensed non-commercial.
- LTX-2: the LTX-2 Community License ([card](https://huggingface.co/Lightricks/LTX-2)) is free only under a revenue threshold. Gated behind `CREATIVE_LTX_LICENCE_OK=1`, as M8c set it up.
- Qwen-Image-2.1: its licence is "other". Not reviewed.

## Cost table (checked 2026-11-23; per-output figures are ESTIMATES)

| Where | GPU | Price | Free quota | Source |
|---|---|---|---|---|
| Kaggle notebook | T4 (16 GB; "T4 x2", ComfyUI uses one) or P100 | $0 | about **30 GPU-hours a week**, sessions up to 12 h, phone-verified account | [NVIDIA / Kaggle](https://developer.nvidia.com/blog/how-kaggle-makes-gpus-accessible-to-5-million-data-scientists/) (30 h/week), [setup guide](https://llcuda.github.io/guides/kaggle-setup) (12 h, phone verification). Your quota is shown in the notebook's session panel |
| Google Colab (free) | T4 | $0 | **unpublished, dynamic** limits; sessions up to 12 h | [Colab FAQ](https://research.google.com/colaboratory/faq.html) |
| RunPod pod | RTX 4090 24 GB | **$0.89/h** | none | [runpod.io/pricing](https://www.runpod.io/pricing) |
| RunPod pod | L40S 48 GB / A40 48 GB / RTX A6000 48 GB / RTX 5090 32 GB | $1.09 / $0.59 / $0.69 / $1.39 per hour | none | same |
| RunPod network volume | - | $0.07/GB-month (under 1 TB) | - | same |
| Vast.ai | RTX 4090 24 GB | from **$0.36/h**, median about $0.47/h (marketplace; plus storage and bandwidth fees per host) | none | [computeprices.com](https://computeprices.com/providers/vast/gpus/rtx4090) (updated 2026-11-23) |
| fal.ai (current path) | hosted | FLUX schnell $0.003/image; Wan 5B about $0.03/video-second; A14B about $0.08/s | none | `creative_studio/hosted_models.json` (M8 estimates) |

Per-output estimates are for a T4 and a 4090. They include ComfyUI overhead, exclude model loading (about 10 to 20 minutes per Kaggle session), and are replaced by `--selftest` numbers.

| Output | T4 time (est.) | 4090 time (est.) | Cost on Kaggle | 4090 on RunPod ($0.89/h) | 4090 on Vast ($0.47/h median) | fal.ai |
|---|---|---|---|---|---|---|
| 1 image, Z-Image Turbo, about 1 MP | about 35 s | about 4 s | $0 | about $0.001 | about $0.0005 | $0.003 (schnell) |
| 1 minute of video, Wan 2.2 5B (12 clips of 5 s) | about 3 to 5 h at 480p | about 1.8 h at 720p (model card: under 9 min per clip) | $0 (about 10% of a week's quota per minute of video) | **about $1.60** | **about $0.85** | about $1.80 |
| 1 minute of talking head, Wan S2V 14B fp8, 480p (about 12 chunks) | does not fit | about 2 h (10 min per chunk, rough) | - | **about $1.80** | **about $0.95** | no equivalent route |
| 1 minute of voice, Kokoro | seconds | seconds | $0 | about $0 | about $0 | - |

**Free weekly capacity on Kaggle (estimate):**
- about 3,000 images;
- or about 6 to 10 minutes of 480p Wan 5B video;
- or a mix of the two.

Talking heads need 24 GB, so they need a rented or owned card. Kaggle's T4 cannot run S2V.

**Conclusion:**
- Images and voice: Kaggle covers the volume at $0.
- Short video: free on Kaggle at 480p.
- At 720p, a rented 4090 on Vast is about half of fal.ai's price, but only while the worker is kept busy. Idle pod time is billed too, so the worker stops itself after 20 to 30 idle minutes.
- Talking-head UGC: about $1 to $2 per finished minute on a rented 4090.

## Start a worker

### (a) Kaggle: free, the first choice
One-time, in your own Kaggle account:
1. **Settings > Phone verification.**
2. Optional: **Add-ons > Secrets**. Add `FZ_WORKER_TOKEN` (any long random text). Put the same text in Railway as `COMFYUI_SELFHOST_TOKEN`.

Each session:
1. Import `creative_studio/selfhost/worker/kaggle_worker.ipynb`:
   - Kaggle: **Create > New Notebook > File > Import Notebook**, then upload the file or paste its GitHub link.
2. Set **Accelerator GPU T4 x2** and **Internet on**.
3. **Run All**.
4. After 10 to 20 minutes, copy the printed `COMFYUI_SELFHOST_URL` (and the token, if you did not set the secret) into **Railway > Variables**.

The quick-tunnel URL changes every session.

Before you rely on it: Kaggle's terms for serving a tunnelled web service were **not confirmed** (the AUP page did not render for review). If Kaggle
objects, run the same notebook in `--batch` mode (no tunnel).

### Colab: batch only
Colab's FAQ forbids, on every managed runtime:
- "web service offerings";
- "connecting to remote proxies".

On free runtimes it also forbids:
- "bypassing the notebook UI to interact primarily via a web UI";
- "running distributed computing workers".

So `colab_batch.ipynb` never opens a tunnel. It runs a JSON batch inside the notebook and gives you a zip of outputs plus `.json` metadata (`ai_generated: true`). Importing them into the studio is an owner step (`creative_owner_import`).

### (b) RunPod / Vast.ai: when the free quota runs out (the owner's spend decision)
- **RunPod:**
  1. **Templates > New Template.** Copy the fields from `creative_studio/selfhost/worker/runpod_template.json` (image, 80 GB container disk, port `8189/http`, the start command, env).
  2. Set `FZ_WORKER_TOKEN` in the template env (the same value as Railway's `COMFYUI_SELFHOST_TOKEN`).
  3. **Deploy** on an RTX 4090.
  4. The log prints `COMFYUI_SELFHOST_URL=https://<pod>-8189.proxy.runpod.net`.
  5. The pod stops itself after `FZ_IDLE_MINUTES` (20) idle or `FZ_MAX_HOURS` (3), using `runpodctl`.
- **Vast.ai:** rent a 24 GB offer with a PyTorch image, at least 80 GB disk and the on-start script `vast_onstart` from the same file. It opens a Cloudflare quick tunnel.
  - Self-stop exits the worker process only. **Destroy the instance in the Vast console when done**, because Vast bills until then.

### (c) Owned hardware later
Linux or Windows with WSL2, a recent NVIDIA driver, Python 3.10 or newer, git, and ffmpeg. Run:

`python3 creative_studio/selfhost/worker/fz_worker.py --profile <t4|24gb|48gb>`

| Profile | What it runs | GPU | System RAM | Disk (weights) |
|---|---|---|---|---|
| `t4` | Z-Image (+LoRA), Wan 5B at 480p, Kokoro | 16 GB (RTX 4060 Ti 16 GB, 4080, T4) | 32 GB | about 39 GB |
| `24gb` | + Wan S2V talking heads, Wan 5B at 720p | 24 GB (RTX 3090 / 4090) | 64 GB | about 56 GB |
| `48gb` | + Wan A14B | 32 to 48 GB (RTX 5090, A6000, L40S) | 64 to 96 GB | about 85 GB |

At home there is no tunnel cost. A used RTX 3090 (24 GB) runs every route here. Power is roughly 350 W under load (an estimate; check your rate).

## Personas: one AI model that looks the same in every post
- A **persona pack** (`persona.json`) lives in the PRIVATE bucket at `<office>/personas/<slug>/persona.json`, next to its reference images. It is never committed to the public repo. It holds:
  - the fixed look as a prompt fragment;
  - the trigger word;
  - the LoRA file name and strength;
  - reference images (studio-generated, or a consented photo);
  - a stock Kokoro voice;
  - `ai_generated: true`, the disclosure, `content_rating: "sfw"` and `adult_age` (21 or more).
- The job's registered character (`creative_owner_add_character`) is matched to the pack by slug.
- **With a LoRA**, only the LoRA workflow runs, and the seed is fixed by persona + prompt, so the same face comes back.
- **Talking heads** use the first reference image.

**Getting the LoRA:**
1. Generate 15 to 25 consistent images of the fictional person (Z-Image with the fixed look).
2. Approve them.
3. Train a LoRA with [ai-toolkit](https://github.com/ostris/ai-toolkit) (MIT) on a rented 24 GB GPU, about 1 h, about $0.50 to $1 (estimate).
4. Copy the file into the worker's `models/loras`.

**Checks:** `persona_problems`, which runs on every job and refuses before any GPU call. Combined with the content rules on every brief, prompt and script, for every provider:
- **No minors.** Age words and school words are refused; the persona must be 21 or older. Music terms such as "C minor" are allowed.
- **No sexual or suggestive content.** A safety negative prompt is added to every selfhost graph as well.
- **No impersonation.** Lookalike, celebrity, deepfake and face-swap requests are refused, and so is "I'm a real person, not AI".
- **No real-person likeness without a recorded consent.** `real_person: true` needs `consent_id`, and photo references need consent. The DB also refuses characters whose consent is missing or revoked.
- **Stock voices only.** No voice cloning.
- **Mandatory AI flag.** Every asset carries `meta.ai_generated = true` (DB-enforced), the caption disclosure and the persona slug.

These are keyword tripwires, not a classifier. A human still approves every post.

## Env

| Variable | Meaning |
|---|---|
| `COMFYUI_SELFHOST_URL` | the worker's https URL (printed by the worker) |
| `COMFYUI_SELFHOST_TOKEN` | the worker's bearer token (printed, or your `FZ_WORKER_TOKEN`) |
| `CREATIVE_FAL_FALLBACK=1` | opt in to fal.ai when selfhost cannot serve a job (fal.ai caps apply) |
| `CREATIVE_LTX_LICENCE_OK=1` | owner confirmed the LTX-Video licence |
| `COMFYUI_SELFHOST_HOURLY_USD` | optional: a rented pod's hourly price, for the meter's estimate |
| `CREATIVE_SELFHOST_QUEUE` | optional: the queue file path (default `~/.fendezy/creative_selfhost_queue.json`) |

## Limits (honest)
- **No GPU here.** Every workflow is unproven on a GPU until the worker's `--selftest` passes. The node and input names for Z-Image and Wan S2V follow the Comfy-Org templates. The adapter's `/object_info` preflight refuses a mismatch before it uses any GPU time.
- **ComfyUI is not pinned yet.** The worker prints the commit it used; pin it with `--comfy-ref` after the first PASS.
- **One S2V chunk is about 4.8 s.** Longer talking heads need the extend nodes or InfiniteTalk (next step).
- **The batch queue is a local JSON file.** On Railway's ephemeral disk a redeploy forgets the pointers. The jobs themselves stay `queued` in the database, but there is no RPC to list them yet (proposal).
- **The quick-tunnel URL changes each Kaggle session.** It must be pasted into Railway each time. A worker-to-Jarvis registration command is a proposal.
