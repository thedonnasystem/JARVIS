# Donna Receptionist v1

Donna's first offer is an AI receptionist for a client business. It:
- answers calls;
- texts back after a missed call;
- books appointments;
- follows up.

It is built by integrating existing systems, not by writing a voice stack.

| Piece | Choice | Licence | Why |
|---|---|---|---|
| Voice agent framework | **Pipecat** `pipecat-ai==1.15.0` | BSD-2-Clause | See "Pipecat or LiveKit Agents" below |
| Telephony and SMS | Twilio (official REST, Media Streams, TwiML) | provider terms | Pipecat's `TwilioFrameSerializer` is built for it; Canadian local numbers |
| STT | Whisper through Pipecat (faster-whisper, local); Deepgram optional | MIT / provider | open by default |
| TTS | **Kokoro** through Pipecat (local, default); Cartesia or ElevenLabs optional | Apache-2.0 / provider | open by default; the voice provider is set in config |
| LLM | `hq_llm.complete` (the free open-model router), `contains_client_data=True` | ours | nothing is hard-coded to one vendor; rules answer first, so most turns need no LLM |
| Booking | **Cal.com hosted API v2** | Cal.com is AGPL-3.0, but we call their hosted API and run none of their code, so the AGPL does not reach ours. If we ever self-host Cal.com, it must run unmodified, or our changes must be published | no calendar adapter exists in the hands pipeline (only the owner's own Google Calendar in `bot.py`), so v1 uses Cal.com |
| CRM | the existing client workspaces: a client is a `client_workspaces` row; callers are its `ws_leads` | ours | Twenty CRM (AGPL) is not needed: ours already has leads, consent and suppression |
| Consent / CASL | the existing `ffm_can_contact`, `ffm_is_phone_suppressed` and `ffm_withdraw_consent` | ours (protected; called, not changed) | one consent system for the whole group |

## Pipecat or LiveKit Agents

**Choice: Pipecat.**

- **No extra infrastructure.** Pipecat runs as one Python process. Twilio Media Streams connect straight to its FastAPI websocket. LiveKit Agents needs
  a LiveKit server (cloud or self-hosted) and a SIP trunk between Twilio and LiveKit.
- **Twilio support built in.** Pipecat ships `TwilioFrameSerializer`, including the auto hang-up.
- **Open services built in.** Kokoro, Whisper, Piper and Silero VAD are already in the package.
- **Same stack as ours.** It is Python, and our only custom piece is one `FrameProcessor` (`receptionist_voice.HqTurns`) that hands each final
  transcription to our rules and `hq_llm`.

LiveKit Agents (Apache-2.0) is the better fit later, if we need WebRTC, multi-party rooms or very large scale.

## How a call flows

1. Twilio calls `POST /twilio/voice/<client>`. The signature is checked, and the call is recorded; the caller becomes or matches a lead in the client's workspace.
2. `hq_receptionist.answer` decides how the call is answered:
   - **Live AI** only when the owner set the client `live` AND the Donna office is active (M1 status plus the M7 profile).
     - `RECEPTION_STREAM=1` runs the Pipecat voice agent: Media Streams, VAD, STT, rules or hq_llm, TTS.
     - Otherwise Twilio `<Gather>` runs turn by turn.
   - **Demo line mode:** a call to `RECEPTION_DEMO_NUMBER` (the owner's demo number) is answered by the AI with the client's config, in Gather mode.
     The cost is low and there is no streaming server.
   - **Anything else** is passed straight to the business's escalation number. No AI answers it.
3. Each turn applies the rules first: a person or urgent, booking, prices, hours, FAQ. The LLM is used only for what the rules don't cover.
   - **Transfer:** `<Dial>` in Gather mode; in stream mode, a Twilio REST call update.
   - **Booking:** service, then three open Cal.com slots, then the caller picks one, then the booking is made and recorded on the call.
4. The status callback records the end of the call. A missed call (no answer, busy, or under 5 s with no speech) queues a text-back, if the owner switched text-back on.

## Texts (CASL; not legal advice, so the owner or counsel should confirm)

Every rule below is enforced in the database (`reception_queue_sms`, `reception_claim_sms`):

- **Identification and opt-out.** The text must name the business and carry "Reply STOP to opt out". It is at most 320 characters.
- **Suppression and opt-out.** A suppressed number, or a lead that withdrew SMS consent, is refused when the text is queued AND again when it is sent
  (`reception_claim_sms` cancels the text).
- **Basis for each kind of text:**
  - `text_back`: only for a missed call from the last 24 hours, and only when the owner switched it on for that client. It answers the caller's own inquiry.
  - `follow_up`: needs current consent in the consent log (`ffm_can_contact(lead, 'sms')`, express or owner-recorded implied consent).
  - `booking_confirm`: only for a call with a booking (transactional).
- **Owner approval.**
  - A client in `demo`, or one whose Donna office is not active, only logs texts as `dry_run`. Those can never be sent or approved.
  - In `live`, every text is `pending_approval` until the owner approves it (`reception_owner_decide_sms`).
  - The one exception is the owner's **standing** rule for one client's missed-call text-back.
- **Sending.** The sender only sends after `reception_claim_sms` returns the text, and only with `RECEPTION_SMS_LIVE=1` on the server.
- **STOP.** STOP, UNSUBSCRIBE, CANCEL, END, QUIT, ARRET or ARRÊT withdraws SMS consent through `ffm_withdraw_consent` and cancels every queued text to
  that number. This works even while the client is paused.
- **Limits.** There is a daily text ceiling per client (default 50). There are **no outbound calls** in v1.

## Per-client config

The shape is in `receptionist/TEMPLATE.json`; a fictional demo is in `receptionist/demo_client.json` (555 numbers only). Real client configs contain
the client's phone numbers, so they are **not** kept in the repo. The owner stores them with `reception_owner_set_client`.

| Key | Content |
|---|---|
| `business_name`, `timezone` | the business and its time zone |
| `hours` | per day, a list of `["HH:MM","HH:MM"]` spans |
| `services` | `name`, `price_cents`, `minutes` |
| `faqs` | `q`, `a` |
| `escalation_number` | the number to transfer to (E.164) |
| `booking` | `provider` (`calcom` or `none`), `event_type_ids` (service to Cal.com event type), `public_url` |
| `voice` | `tts` (`kokoro` default, `twilio-say`, `cartesia`, `elevenlabs`), `stt` (`whisper-local` or `deepgram`), `voice_id`, `language` |

## Cost per call (ESTIMATES; verify on twilio.com/pricing and the provider pages)

Prices are US$ list prices converted at x 1.40 to CAD:

| Item | Estimate |
|---|---|
| Canadian local number | about US$1.15/month (the demo number is an **owner spend approval**) |
| Inbound voice | about US$0.0085/min |
| Media Streams | about US$0.004/min |
| Twilio speech recognition (Gather) | about US$0.02 per turn |
| Kokoro TTS | $0 (runs on our server) |
| Whisper STT | $0 (runs on our server) |
| Deepgram STT | about US$0.0043/min |
| hq_llm turns | $0 on the free routes, inside the AI cap |
| SMS | about US$0.0083 per segment, plus about US$0.003 carrier fee |

For a typical 3-minute call:
- **Stream mode** (Pipecat, local STT/TTS): about **C$0.06**. With Deepgram: about C$0.08.
- **Gather / demo-line mode:** about **C$0.21** (6 turns).
- **A text-back:** about **C$0.02**.

The estimate is stored on every call (`calls.cost_est_cents`) and shown in `/reception`.

## Files

| File | Content |
|---|---|
| `migrations/20261206_donna_receptionist_v1.sql` | schema `fz_reception`: clients, calls, messages, and the rules |
| `ops/rollback_donna_receptionist.sql` | archives to `fz_archive` |
| `sqltests/donna_receptionist_check.sql` | proof of the rules |
| `hq_receptionist.py` | config, hours, turn rules, booking flow, TwiML, Twilio signature, SMS sender, Cal.com, cost |
| `receptionist_voice.py` | Pipecat pipeline (lazy imports) |
| `receptionist_server.py` | FastAPI webhooks |
| `requirements-receptionist.txt` | pinned server dependencies |
| `/reception` | owner, read-only |
| `ops/OWNER_RECEPTIONIST.sql` | owner steps |
| `test_hq_receptionist.py` | Twilio, Cal.com and the LLM mocked; no network |

## Deployment (owner)

1. Apply the migration (in APPLY_ORDER, before the lockdown).
2. Create the client's workspace, then run `ops/OWNER_RECEPTIONIST.sql`: the client config, staying in `demo`.
3. Deploy `receptionist_server.py` as its own Railway service:
   - `pip install -r requirements-receptionist.txt`, then `uvicorn receptionist_server:app`;
   - variables: `RECEPTION_BASE_URL`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `RECEPTION_DEMO_NUMBER`, plus `CALCOM_API_KEY` if booking is used;
   - the existing `HQ_SUPABASE_*` variables.
4. **Demo line** (an owner spend approval: one Canadian local number, about US$1.15/month): buy it in the Twilio console, then set its voice, status and
   messaging webhooks to the URLs above. Call it to hear the client's receptionist. Texts stay `dry_run`.
5. **Going live** for a client takes all of these:
   - Donna active;
   - the client's own Twilio number set;
   - `reception_owner_set_flags(slug, 'live', text_back, standing)`;
   - `RECEPTION_STREAM=1` (optional);
   - `RECEPTION_SMS_LIVE=1` only when texts should really go out.

**Rollback:** run `ops/rollback_donna_receptionist.sql`. Leads, consent and withdrawals stay in the CRM.
