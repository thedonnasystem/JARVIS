"""Donna Receptionist v1: the real-time voice agent, built on Pipecat (BSD-2-Clause, pinned pipecat-ai==1.15.0 in requirements-receptionist.txt).

Pipeline: Twilio Media Streams (TwilioFrameSerializer) -> Silero VAD -> STT -> HqTurns -> TTS -> Twilio.
- STT: Whisper (local, faster-whisper) by default; Deepgram is optional.
- HqTurns is OUR only processor. It sends each final transcription to hq_receptionist.Conversation, which runs the rules first and then
  hq_llm.complete with contains_client_data=True. It pushes the reply as a TTSSpeakFrame.
- TTS: Kokoro (open, local) by default; Cartesia / ElevenLabs are optional premium providers.
- Transfer: the live call is redirected through Twilio's REST API to <Dial> the client's escalation number.

Pipecat is imported lazily, so the bot and the unit tests never need it installed.
"""
from __future__ import annotations

import asyncio
import base64
import logging
import os
import urllib.parse

import hq_receptionist as R

logger = logging.getLogger(__name__)


def stt_service(cfg: dict, env: dict):
    kind = (cfg.get("voice") or {}).get("stt", "whisper-local")
    if kind == "deepgram":
        from pipecat.services.deepgram.stt import DeepgramSTTService
        return DeepgramSTTService(api_key=env["DEEPGRAM_API_KEY"])
    from pipecat.services.whisper.stt import WhisperSTTService
    return WhisperSTTService(device="cpu", compute_type="int8")


def tts_service(cfg: dict, env: dict):
    v = cfg.get("voice") or {}
    kind = v.get("tts", "kokoro")
    if kind == "cartesia":
        from pipecat.services.cartesia.tts import CartesiaTTSService
        return CartesiaTTSService(api_key=env["CARTESIA_API_KEY"], voice_id=v.get("voice_id"))
    if kind == "elevenlabs":
        from pipecat.services.elevenlabs.tts import ElevenLabsTTSService
        return ElevenLabsTTSService(api_key=env["ELEVENLABS_API_KEY"], voice_id=v.get("voice_id"))
    from pipecat.services.kokoro.tts import KokoroTTSService
    return KokoroTTSService(voice_id=v.get("voice_id") or "af_heart")


def transfer_call(call_sid: str, number: str, env: dict, http=None) -> bool:
    """Redirect the live call to <Dial> the escalation number (Twilio REST: update call with new TwiML)."""
    sid, tok = env.get("TWILIO_ACCOUNT_SID") or "", env.get("TWILIO_AUTH_TOKEN") or ""
    if not (sid and tok and R.PHONE.match(number or "")):
        return False
    if http is None:
        import hq_hands_adapters
        http = hq_hands_adapters.http
    auth = base64.b64encode(f"{sid}:{tok}".encode()).decode()
    st, _, _ = http("POST", f"https://api.twilio.com/2010-04-01/Accounts/{urllib.parse.quote(sid)}/Calls/{urllib.parse.quote(call_sid)}.json",
                    headers={"Authorization": f"Basic {auth}"}, form={"Twiml": f"<Response><Dial>{number}</Dial></Response>"})
    return st in (200, 201)


def make_turn_processor(conv: "R.Conversation", on_action=None):
    """The one custom Pipecat processor: final transcription -> Conversation.handle (in a thread: hq_llm is blocking) -> TTSSpeakFrame."""
    from pipecat.frames.frames import TranscriptionFrame, TTSSpeakFrame
    from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

    class HqTurns(FrameProcessor):
        async def process_frame(self, frame, direction: FrameDirection):
            await super().process_frame(frame, direction)
            if isinstance(frame, TranscriptionFrame) and (frame.text or "").strip():
                r = await asyncio.to_thread(conv.handle, frame.text)
                await self.push_frame(TTSSpeakFrame(r["say"]))
                if r.get("action") and on_action:
                    await asyncio.to_thread(on_action, r["action"])
                return
            await self.push_frame(frame, direction)

    return HqTurns()


async def run_call(websocket, client: str, *, rpc=None, env: dict | None = None, llm=None) -> None:
    """Handle one Twilio Media Stream for a LIVE client (the /voice webhook only streams when the DB says live + Donna active)."""
    from pipecat.audio.vad.silero import SileroVADAnalyzer
    from pipecat.frames.frames import TTSSpeakFrame
    from pipecat.pipeline.pipeline import Pipeline
    from pipecat.pipeline.runner import PipelineRunner
    from pipecat.pipeline.task import PipelineTask
    from pipecat.processors.audio.vad_processor import VADProcessor
    from pipecat.runner.utils import parse_telephony_websocket
    from pipecat.serializers.twilio import TwilioFrameSerializer
    from pipecat.transports.websocket.fastapi import FastAPIWebsocketParams, FastAPIWebsocketTransport

    env = dict(os.environ) if env is None else env
    rpc = rpc or R._rpc_default
    c = rpc("reception_client_config", {"p_slug": client})
    if not c.get("live"):
        await websocket.close()
        return
    cfg = R.validate(c["config"])
    _, call = await parse_telephony_websocket(websocket)
    calcom = R.CalCom(env["CALCOM_API_KEY"]) if cfg["booking"].get("provider") == "calcom" and env.get("CALCOM_API_KEY") else None
    if llm is None:
        import hq_llm
        llm = hq_llm.complete
    conv = R.Conversation(cfg, llm=llm, calcom=calcom)

    def on_action(action: str):
        if action == "transfer":
            transfer_call(call["call_id"], cfg["escalation_number"], env)
            rpc("reception_call_event", {"p_slug": client, "p_call_sid": call["call_id"], "p_from": None, "p_status": "escalated"})
        elif action == "booked" and conv.booking_ref:
            rpc("reception_booking_record", {"p_call_sid": call["call_id"], "p_booking_ref": conv.booking_ref})

    serializer = TwilioFrameSerializer(stream_sid=call["stream_id"], call_sid=call["call_id"], account_sid=env.get("TWILIO_ACCOUNT_SID"),
                                       auth_token=env.get("TWILIO_AUTH_TOKEN"))
    transport = FastAPIWebsocketTransport(websocket=websocket, params=FastAPIWebsocketParams(audio_in_enabled=True, audio_out_enabled=True,
                                                                                               add_wav_header=False, serializer=serializer))
    pipeline = Pipeline([transport.input(), VADProcessor(vad_analyzer=SileroVADAnalyzer()), stt_service(cfg, env), make_turn_processor(conv, on_action),
                         tts_service(cfg, env), transport.output()])
    task = PipelineTask(pipeline)

    @transport.event_handler("on_client_connected")
    async def _hello(_t, _c):
        await task.queue_frames([TTSSpeakFrame(f"Hi, thanks for calling {cfg['business_name']}. I'm an AI assistant. How can I help?")])

    @transport.event_handler("on_client_disconnected")
    async def _bye(_t, _c):
        await task.cancel()

    await PipelineRunner(handle_sigint=False).run(task)
