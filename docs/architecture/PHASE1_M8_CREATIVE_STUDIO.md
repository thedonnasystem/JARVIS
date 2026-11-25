# Phase 1, M8: FENDEZY AI CREATIVE STUDIO

Slug `creative-studio`; the M5 registry key is `creative_studio`. M8 is one shared group department that makes images, video, UGC (AI presenters),
voice, music, copy and edits for all 8 offices. It replaces a paid creative subscription for each business.

This milestone merges M8a and M8b. It contains:
- the data model, the router gates, the asset registry and the pipeline worker;
- a hosted open-weight adapter for fal.ai. Replicate is a registry slot only, because the protected `test_no_bypass` allow-list does not include this module (owner proposal);
- the sandbox end-to-end demo.

M8c (below) adds the template / preset library, burned word-timed captions, the editing upgrades, the self-hosted ComfyUI path and the analytics loop.
Components and licences are listed in `CREATIVE_STUDIO_COMPONENTS.md`.

## Pieces

| Piece | Where |
|---|---|
| Schema `fz_creative` (no API privileges) and the `creative_*` definer functions | `migrations/20261205_creative_studio_v1.sql` |
| Rollback (archives every table to `fz_archive`) | `ops/rollback_creative_studio.sql` |
| DB proof: money fingerprint, gates, isolation, audit lock | `sqltests/creative_studio_check.sql` |
| Router, money flow, QA, ffmpeg edit/render, adapters, storage, publishing | `hq_creative_studio.py` |
| Hosted model endpoints and prices (estimates) | `creative_studio/hosted_models.json` |
| `/creative` (owner, read-only) | `hq_commands.hq_creative_cmd` |
| Sandbox e2e demo; first real run (owner only) | `scripts/creative_studio_demo.py`, `scripts/creative_studio_first_run.py` |
| Owner release steps | `ops/OWNER_CREATIVE_STUDIO.sql`, `ops/proposals/creative_studio_registry.md` |

## Architecture

- **One service, separate brand environments.**
  - Every job, attempt, asset, character and calendar entry carries its office.
  - Each office has its own brand kit; the group has one too.
  - Files live in ONE private Storage bucket under `<office>/...`, so a path outside the job's office is refused.
  - A scoped identity cannot call the studio functions at all.
  - The service-path asset read `creative_assets(office)` returns one office only.
- **Shared brain.**
  - The worker reads facts through M7's `hq_office_os.brain_facts` (M6 `fz_brain_read`, which is office-scoped and fails closed).
  - Nothing crosses office permissions.
  - Writing learnings back to the brain comes later; M8c ranks templates and hooks inside the studio.
- **No new infrastructure.**
  - Metadata is in the HQ database; files are in Supabase Storage.
  - Publishing uses the Jarvis hands pipeline. Postiz is not used, because the hands pipeline already has the owner approval gate.
  - LLM calls (optional) go through the `hq_llm.complete` contract.
- **One pipeline worker runs 11 roles as steps:**
  - research: market research, trend analysis;
  - strategy, copy and scripts, creative direction;
  - image and video generation, editing, QA;
  - publishing, analytics.

  The flow is Brief, Research, Strategy, Script, Direction, Generation, Editing, QA, Approval, Publishing, Analytics. Only the script step may call an
  LLM, and only when one is passed. The sandbox uses templates and costs nothing.

## Model router (each request)

1. **Content type** is the job's module: video / image / ugc / voice / music / copy / edit / train (LoRA).
2. **Quality** is the tier, draft < standard < high < hero, plus the platform frames 9:16 (1080x1920), 1:1 (1080x1080) and 16:9 (1920x1080).
3. **Estimate** comes from `creative_studio/hosted_models.json` (USD list price x 1.40, rounded up) or the registry price.
4. **Cheapest qualified model** comes from a provider the owner enabled, whose key is set, and whose adapter exists. "Qualified" means the model serves the tier.
5. **Generate.** The DB gate runs first (`creative_attempt_begin`), then the spend gate reserves for any attempt over 0 cents, then the provider is called.
6. **QA** is deterministic:
   - the file must be readable and contain a picture, in the platform frame;
   - the AI-generated disclosure must be present;
   - the brand-kit "dont" list and required disclaimers are checked;
   - there must be no testimonial / review / real-customer framing.
7. **Escalate** to the next candidate.
   - Premium is used only after QA failed an open-source attempt AND the owner allowed premium for the job or office.
   - Exception: a **hero** job may go premium directly, but only when the office preset says `hero_premium` AND the owner allowed premium for that office.
8. **Record** the actual cost, QA score and time (`creative_attempt_end`), along with the reservation.

**Limits:**
- `max_attempts` per office: default 3, hard ceiling 5, enforced in the DB.
- One open attempt at a time.
- A daily job ceiling per office (default 20).
- An OPTIONAL owner-set weekly creative limit per office (default none).
- A failed provider call releases its reservation.
- A denied or ask-owner spend gate stops the attempt: nothing is spent.

**Per-office budgets (flag).** The Chairman's rule of Nov 19 is "no fixed or equal budgets; offices draw on need". So M8 has no budget allocation of its
own. It tracks spend per office (shown in the report) and has optional owner-set creative limits. Money is still allocated by M2 office money, and every
paid attempt passes the existing office spend gate (caps, per-transaction and weekly limits, owner approval rules).

## Office presets (seeded; the owner can edit them with `creative_owner_set_preset`)

| Office | Module | Tier | Models (preferred first) | Notes |
|---|---|---|---|---|
| B2B Records | image | high | flux.1-dev-lora, flux.1-schnell | cover art / visualizer stills with the artist LoRA (artist look only with consent) |
| B2B Records | video | high | wan-2.2-t2v-a14b, ltx-2 | lyric / visualizer video |
| B2B Records | music | high | ace-step | open model slot (adapter not built yet) plus the premium music slot. **Never imitate a named real artist** (QA refuses "in the style of", "sounds like" and similar) |
| Pimp AI | image / video / train | high | flux.1-dev-lora; wan / ltx; flux-lora-trainer | one LoRA per registered character. Real-person likeness only with recorded consent (DB-enforced). Platform rules and the prohibited list apply |
| The Trap | image | high | flux.1-dev, flux.1-schnell | product photography (product reference via `reuse_of` / reference image; IP-adapter and relight workflows come with the ComfyUI path) |
| The Trap | video | standard | wan-2.2-ti2v-5b, ltx-2 | short product videos |
| FF Marketing | video | **hero**, hero_premium | kling-3.0, veo-3.1, gen-4, wan-2.2-t2v-a14b | hero ads go premium when the owner allows it; open models make the variations |
| FF Marketing | image | high | flux.1-dev, flux.1-schnell | ad stills |

## Assets

- Asset kinds: brand_guideline, logo, graphic, character, product_photo, voice, video_template, campaign, generated, lora.
- Every generated asset has `meta.ai_generated = true` (DB-enforced). Captions carry "AI-generated content." (DB-enforced at finish and on the calendar).
- **Version history:** the same name gets version n+1, with `previous_id` pointing at version n.
- **Reuse:** `creative_assets(office, best => true)` ranks approved generated assets by recorded performance. A new job can name one as `reuse_of`
  (same office only) and receives it as a reference input.
- **Manual import:** `creative_owner_import` registers an asset the owner made by hand in any tool (e.g. Higgsfield) with its source and the cost paid
  outside, so the report includes it. There is no Higgsfield integration because no official API is confirmed.

## Compliance

- UGC and AI presenters always carry the AI label and the disclosure.
- Content is never presented as a real customer, testimonial or review. This maps to the `deceptive_communication` / `fabricate` blocks.
- A real person's likeness or voice requires `creative_owner_record_consent`. This is checked at submit and for characters, and a revoked consent stops new jobs.
- Nothing is published from the studio. `schedule_post` creates a hands DRAFT, and the owner approves it through the existing flow, or an owner-set
  standing rule applies.

## M8c: templates, captions, editing, ComfyUI, analytics

| Piece | Where |
|---|---|
| Template / preset library (data) | `creative_studio/presets/library.json` (21 templates, hooks, caption styles, vocabulary) |
| Library validation, prompt compiler, workflow filling | `hq_creative_presets.py` |
| Captions, loudness, reframe, beat cuts, B-roll, visualizer | `hq_creative_media.py` |
| ComfyUI API-format workflows + licence manifest | `creative_studio/comfyui/` |
| ComfyUI (RunPod) + local-edit adapters, template choice, metrics import, ranking | `hq_creative_studio.py` |
| DB: `templates`, `job_templates`, `platform_metrics`, 6 functions, `local-edit` provider | `migrations/20261207_creative_studio_v2.sql` |
| Rollback (M8c only / whole studio) | `ops/rollback_creative_studio_v2.sql` / `ops/rollback_creative_studio.sql` |
| DB proof | `sqltests/creative_studio_v2_check.sql` |
| Seed = library check | `scripts/creative_presets_seed.py --check` (unit test) |

**Templates are data, never routing.** A template sets prompt vocabulary (shot type, camera move, camera body, lens, focal length, aperture, lighting,
mood, UGC format), a negative prompt, video length / fps, an edit recipe (fit, captions style, hook-first, B-roll, beat sync, loudness, visualizer),
hooks and a ComfyUI workflow id. It cannot name a provider, model, price or the disclosure: the Python validator and a DB `CHECK` on the spec keys refuse
it, and a second `CHECK` refuses testimonial / review / real-customer framing and real-artist imitation. The router, the spend gate, premium rules,
retries and owner approval are unchanged (`sqltests/creative_studio_v2_check.sql` V5 proves premium is still refused for a templated job).

**Which template a job gets.** The one requested (`creative_job_set_template`), else the office's best-ranked template for the module
(`creative_rank`), with 1 job in 5 exploring another one, else the office default. Edit jobs always name theirs (they need input clips). A template that
needs a character LoRA is only used when the job has a registered character (the v1 consent rules apply). Office isolation: a template is the office's
own or the group's; edit inputs are approved (or uploaded library) assets of the same office.

**Editing step (every video).** fit (pad with the brand colour, or auto-reframe on the visual-energy centre) -> captions -> hook banner (first 2.5 s) ->
the "AI-generated" label (always; it is drawn even when captions are off) -> loudness normalisation (EBU R128, -14 LUFS, true peak -1.5 dB) -> H.264 /
AAC, soft SRT track, SRT sidecar in Storage, disclosure in the metadata.
- Captions: faster-whisper (CPU, int8, word timestamps), in a separate process (`creative_studio/tools/whisper_words.py`; see `ops/proposals/creative_media_deps.md` for why). When the speech is the known script / lyrics, the words keep whisper's timing and the script's
  spelling. Without whisper or speech, the script is timed evenly (video, UGC, music) or there are no captions (edit jobs).
- Styles per office brand kit: karaoke (word highlight), pop (one word, scale-in), lyric, subtle; the kit's second colour is the highlight, its first
  font is used.
- QA adds the spoken words: deceptive framing or a brand-kit "dont" word in the transcript fails the job.
- Edit jobs (`local-edit`, free, OFF until the owner enables it): B-roll stitch of the inputs (hard cuts or crossfades), hook-first order by motion,
  beat-synced cuts on the music input (librosa when installed; a pure-Python onset tracker otherwise), auto-reframe per clip.
- Music (B2B Records): visualizer (waves / spectrum over the cover art from `reuse_of`) and lyric video (word-timed lyrics), stored next to the audio.

**ComfyUI (self-hosted, later cost step).** Workflows for FLUX.1 schnell (+ LoRA), Wan 2.2 TI2V-5B and T2V-A14B, LTX-Video are checked in (API format,
typed placeholders). `ComfyUIAdapter` posts them to a RunPod serverless endpoint running worker-comfyui, through `hq_hands_adapters.http` (the allowed
outbound path; `runpod` is not a provider pattern in `test_no_bypass`). It runs only in live mode with the owner-enabled `runpod-comfyui` row,
`RUNPOD_API_KEY` and `COMFYUI_RUNPOD_ENDPOINT`. Each run is capped at the reserved GPU-seconds (`policy.executionTimeout`), so the measured cost cannot
exceed the reservation. Only models with a shipped, commercially usable workflow are routed (FLUX.1 [dev] and HunyuanVideo were removed from the
self-host rows). Modal stays a slot: `ops/proposals/creative_comfyui_selfhost.md`.

**Analytics loop.** Metrics come in by CSV (`parse_metrics_csv` -> `import_metrics`, source `manual`) or from a hands-pipeline insights result
(`hands_metrics`, keyed by the hand action; the calendar maps it to the asset; source `hands`). `creative_metrics_import` accepts only the office's
own assets, validates every row (unknown metric, negative value, completion rate over 1 are reported, not written) and replaces the value on a
re-import of the same window. `creative_rank` scores each approved asset on its latest metrics (engagement and outcomes per view, 3-second hold,
completion) and ranks templates and hooks with a prior of 3 posts at the office mean, so one lucky post does not win. `rank_text(office)` is the
one-line summary for Jarvis / the owner.

**M8c env.** `CREATIVE_WHISPER_DIR` (folder with the faster-whisper model), `CREATIVE_WHISPER_MODEL` (default `tiny`; `base` / `small` are more accurate
and slower), `CREATIVE_WHISPER_DOWNLOAD=1` (allow the one-time model download), `COMFYUI_RUNPOD_ENDPOINT` (RunPod endpoint id; with `RUNPOD_API_KEY`).

**M8c rollback.** `ops/rollback_creative_studio_v2.sql`: archives the three tables to `fz_archive`, drops the six functions, switches `local-edit` off
and restores the v1 self-host model list. The worker falls back to v1 behaviour by itself (no template), and the new editing step needs no database.
To undo the code too, revert the M8c commit.

## Env config

| Variable | Meaning |
|---|---|
| `CREATIVE_STUDIO_MODE` | `sandbox` (default: sandbox adapter (and the free local-edit adapter) only, no network) or `live` |
| `FAL_KEY` | fal.ai key (hosted open-weight models). Owner sign-up |
| `REPLICATE_API_TOKEN` | Replicate token: slot only, no adapter yet |
| `CREATIVE_VIDEO_SECONDS` | default video length (5) |
| `HQ_SUPABASE_URL`, `HQ_SUPABASE_SERVICE_KEY` | existing; used for the RPCs and the private bucket |
| `FZ_BRAIN_FACTS=1` | existing M7 flag: brain facts in the research step |
| later: `RUNPOD_API_KEY` / `MODAL_TOKEN_ID`, `GOOGLE_API_KEY`, `KLING_API_KEY`, `RUNWAY_API_KEY`, `ELEVENLABS_API_KEY`, `CREATIVE_MUSIC_API_KEY`, `CREATIVE_AGGREGATOR_KEY` | registry slots with no adapter yet: never routed to |

## Deployment (owner)

1. Apply `migrations/20261205_creative_studio_v1.sql` in APPLY_ORDER (after M7, before the lockdown). It is additive and safe to re-run.
2. Run `ops/OWNER_CREATIVE_STUDIO.sql`: step 1 registers the service, step 2 creates the private bucket, then brand kits and providers.
3. Leave `CREATIVE_STUDIO_MODE` unset (sandbox) until the first real run.
4. Sandbox proof on a scratch replica:
   `python3 scripts/creative_studio_demo.py --db <scratch url>`
   This runs in one transaction and rolls back.
5. **First real run.** Sign up for fal.ai, put the key in Railway Variables, enable that provider, then run:
   `CREATIVE_STUDIO_MODE=live python3 scripts/creative_studio_first_run.py --office <slug>`
   That command only runs checks. Add `--run --max-cents 50` for one image and one 5 s video. The estimated total is under C$0.30; it goes through the spend gate.

**Rollback:** run `ops/rollback_creative_studio.sql`. It archives every table with its rows into `fz_archive`. Then set the `fz_services` row to `retired`.

## Failure recovery

| Failure | What happens |
|---|---|
| Provider error or timeout | The attempt ends as `error`, the reservation is released, and the next candidate runs within the retry limit |
| QA failure | The attempt ends as `qa_failed`; escalation follows the rules above |
| Spend gate deny / ask_owner | The attempt ends as `error` with 0 cents; the job fails with the gate's reason; nothing is spent |
| Render / upload error | The job fails with the reason; attempts are already closed |
| Worker crash mid-attempt | The open attempt blocks new attempts on that job (the DB refuses). The owner can see it in `/creative`. Reservations expire under the existing capital rules |
| Office goes dormant | Claim, attempts, assets and the calendar refuse |
| Studio not registered or retired | Every write refuses |

## Operating cost report (ESTIMATES, CAD; verify on each provider's pricing page)

| Output | Model / path | Estimate |
|---|---|---|
| Image | FLUX.1 schnell, fal | about C$0.004 (billed 1 cent) |
| Image | FLUX.1 dev, fal | about C$0.035 |
| Image with character LoRA | flux-lora, fal | about C$0.05 |
| 5 s video | Wan 2.2 5B, fal | about C$0.21 |
| 5 s video | Wan 2.2 A14B, fal | about C$0.56 |
| 5 s video | LTX-2 fast, fal | about C$0.28 |
| LoRA training (one character) | flux-lora-fast-training, fal | about C$2.80 per run |
| 5 s premium video (fallback / hero) | Kling 3.0 | about C$0.75 |
| 5 s premium video (fallback / hero) | Veo 3.1 | about C$2.80 |
| Edit / render / captions (faster-whisper on the CPU, ffmpeg) | Jarvis host | C$0 (CPU time measured in the sandbox: about 3 s for 12 s of speech with `tiny`) |

**Example month.** All 8 offices, 20 images and 8 short videos each, with 1.5 attempts on average:
- about C$30 on open models;
- plus any approved hero ads.

For comparison, eight C$99/month creative subscriptions cost about C$790.

## Provider sign-up list (owner; costs are ESTIMATES)

| Provider | What | Pricing (estimate) | Key | Priority |
|---|---|---|---|---|
| fal.ai | hosted FLUX, Wan 2.2, LTX-2, LoRA training | pay per call, see above | `FAL_KEY` | **first** |
| Replicate | hosted FLUX, Wan 2.2 (adapter pending the owner's allow-list decision) | pay per call / GPU-second | `REPLICATE_API_TOKEN` | later |
| RunPod serverless or Modal | our own ComfyUI workflows (later cost optimisation) | about US$0.0005 to US$0.0011 per GPU-second | `RUNPOD_API_KEY` / `MODAL_TOKEN_ID` | later |
| Kling / Google Veo / Runway | premium video fallback, FF Marketing hero ads | about US$0.10 to US$0.40 per second | per provider | after hero demand |
| ElevenLabs | premium voice | about US$0.30 per minute | `ELEVENLABS_API_KEY` | optional |
| Premium music API | provider not chosen | check ownership terms of generated music | `CREATIVE_MUSIC_API_KEY` | optional |
| "Treg" | unidentified aggregator: the generic slot is reserved | unknown | `CREATIVE_AGGREGATOR_KEY` | identify first |
