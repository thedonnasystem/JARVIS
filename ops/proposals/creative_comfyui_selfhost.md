# Proposal: self-hosted ComfyUI for the creative studio (RunPod first, Modal later)

Status: owner decision (accounts, money). The code path exists in M8c; nothing is enabled.

## What is built
- Five ComfyUI workflows in API format (`creative_studio/comfyui/`): FLUX.1 schnell, FLUX.1 schnell + character LoRA, Wan 2.2 TI2V-5B,
  Wan 2.2 T2V-A14B, LTX-Video. Their weights are listed with licences in `manifest.json`; FLUX.1 [dev] and HunyuanVideo are deliberately absent.
- `ComfyUIAdapter` in `hq_creative_studio.py` for a **RunPod serverless endpoint running worker-comfyui unmodified** (AGPL-3.0: calling it over HTTPS
  does not oblige us to publish anything; modifying and serving it would). All HTTP goes through `hq_hands_adapters.http` (https only, no redirects).
  Allowed by the protected `test_no_bypass`: `runpod` is not one of its provider patterns, and this is the same outbound path fal.ai uses.
- Money: every run is reserved through the office spend gate first (the provider row is `gpu-second`, 0.075 CAD cents per GPU-second estimate); the
  run is capped at the reserved GPU-seconds by RunPod's `policy.executionTimeout`; the settled amount is the measured execution time x the rate.

## Owner steps (when hosted fal.ai costs justify it)
1. RunPod account, a network volume with the model files from `manifest.json` (models/checkpoints, diffusion_models, text_encoders, vae, loras).
2. A serverless endpoint from the worker-comfyui image (pin the tag; the adapter expects the 5.x API: `input.workflow`, output `images[]` as base64 or
   `s3_url`). Check one output by hand, especially video outputs, before enabling.
3. Railway Variables: `RUNPOD_API_KEY`, `COMFYUI_RUNPOD_ENDPOINT` (the endpoint id). Then `select public.creative_owner_set_provider('runpod-comfyui', true);`
4. LTX-Video: read the LTX licence for the checkpoint you install before enabling `ltx-video`; LTX-2 is free only under US$10M group revenue.
5. Character LoRAs: copy the approved LoRA file to the volume's `loras/` folder under its asset file name (the adapter passes that name).

## Modal (not built)
Modal needs its own client protocol (a deployed web endpoint we would write and host on Modal, MIT example `modal-labs/modal-examples`). It would go
through the same `hq_hands_adapters.http` path. Build it only if RunPod does not fit.

## Expected saving (ESTIMATES)
48GB-class GPU about US$0.00053/s. FLUX schnell about 4 GPU-s (C$0.003), Wan 2.2 5B 5 s clip about 125 GPU-s (C$0.09 vs about C$0.21 on fal),
A14B about 450 GPU-s (C$0.34 vs about C$0.56). Cold starts are billed too; the saving appears from roughly a few hundred clips a month.
