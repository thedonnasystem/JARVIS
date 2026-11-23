"""Donna Receptionist v1: the webhook server, a separate process from bot.py. It is a thin FastAPI app (FastAPI comes with Pipecat).

    RECEPTION_BASE_URL=https://<public host> uvicorn receptionist_server:app --port 8080

Twilio number webhooks (set by the owner in the Twilio console):
- Voice: POST {base}/twilio/voice/<client>
- Status callback: POST {base}/twilio/status/<client>
- Messaging: POST {base}/twilio/sms/<client>

Every HTTP webhook must carry a valid X-Twilio-Signature (TWILIO_AUTH_TOKEN), or it gets a 403. This process places no outbound calls.
A text is sent only by the sender loop, and only for messages the database returns as approved (RECEPTION_SMS_LIVE=1 is also required).

Modes:
- Demo line: calls to RECEPTION_DEMO_NUMBER, the owner's number, go through Twilio <Gather> turn by turn.
- Live: the client's own number, when the owner set it live AND the Donna office is active. RECEPTION_STREAM=1 uses the Pipecat voice agent;
  otherwise the Gather mode is used.
"""
from __future__ import annotations

import os

import hq_receptionist as R

try:
    from fastapi import FastAPI, Request, Response, WebSocket
except Exception:                                                                # the bot image does not ship fastapi
    FastAPI = None

CONVS: dict[str, R.Conversation] = {}
MAX_CONVS = 500


def _env():
    return os.environ


def _url(request) -> str:
    base = (_env().get("RECEPTION_BASE_URL") or "").rstrip("/")
    return base + request.url.path + (("?" + request.url.query) if request.url.query else "")


async def _form(request) -> dict:
    return {k: str(v) for k, v in (await request.form()).items()}


def _xml(body: str, status: int = 200):
    return Response(content=body, media_type="application/xml", status_code=status)


def handle_turn(client: str, form: dict, *, rpc=None, base_url: str, llm=None, calcom=None) -> str:
    """Gather-mode turn (pure: tested without FastAPI). Conversation state lives in memory per CallSid (one process; bounded)."""
    rpc = rpc or R._rpc_default
    c = rpc("reception_client_config", {"p_slug": client})
    cfg = R.validate(c["config"])
    sid = form.get("CallSid") or ""
    conv = CONVS.get(sid)
    if conv is None:
        if len(CONVS) >= MAX_CONVS:
            CONVS.pop(next(iter(CONVS)))
        conv = CONVS[sid] = R.Conversation(cfg, llm=llm, calcom=calcom)
    xml, r = R.twiml_turn(cfg, form.get("SpeechResult") or "", f"{base_url}/twilio/turn/{client}", conv=conv)
    if r.get("action") == "transfer":
        rpc("reception_call_event", {"p_slug": client, "p_call_sid": sid, "p_from": form.get("From"), "p_status": "escalated"})
    elif r.get("action") == "booked" and conv.booking_ref:
        rpc("reception_booking_record", {"p_call_sid": sid, "p_booking_ref": conv.booking_ref})
    return xml


def handle_status(client: str, form: dict, *, rpc=None) -> dict:
    """Status callback: record the call; a missed call queues a text-back (the DB decides: off / dry_run / pending owner / standing)."""
    rpc = rpc or R._rpc_default
    r = R.status_event(client, form, rpc=rpc)
    CONVS.pop(form.get("CallSid") or "", None)
    if r.get("status") in ("missed", "voicemail"):
        c = rpc("reception_client_config", {"p_slug": client})
        if c.get("text_back_enabled"):
            try:
                return {"call": r, "text_back": R.queue_text_back(R.validate(c["config"]), form.get("CallSid"), rpc=rpc)}
            except Exception as e:
                return {"call": r, "text_back": {"refused": str(e)[:200]}}
    return {"call": r}


if FastAPI is not None:
    app = FastAPI(title="Donna Receptionist", docs_url=None, redoc_url=None, openapi_url=None)

    async def _checked(request) -> dict | None:
        form = await _form(request)
        if not R.verify_twilio(_env().get("TWILIO_AUTH_TOKEN", ""), _url(request), form, request.headers.get("X-Twilio-Signature")):
            return None
        return form

    @app.post("/twilio/voice/{client}")
    async def voice(client: str, request: Request):
        form = await _checked(request)
        if form is None:
            return Response(status_code=403)
        e = _env()
        return _xml(R.answer(client, form, base_url=e["RECEPTION_BASE_URL"].rstrip("/"), demo_number=e.get("RECEPTION_DEMO_NUMBER"), stream=e.get("RECEPTION_STREAM") == "1"))

    @app.post("/twilio/turn/{client}")
    async def gather_turn(client: str, request: Request):
        form = await _checked(request)
        if form is None:
            return Response(status_code=403)
        import hq_llm
        e = _env()
        cfg = R.validate(R._rpc_default("reception_client_config", {"p_slug": client})["config"])
        cal = R.CalCom(e["CALCOM_API_KEY"]) if cfg["booking"].get("provider") == "calcom" and e.get("CALCOM_API_KEY") else None
        return _xml(handle_turn(client, form, base_url=e["RECEPTION_BASE_URL"].rstrip("/"), llm=hq_llm.complete, calcom=cal))

    @app.post("/twilio/status/{client}")
    async def status(client: str, request: Request):
        form = await _checked(request)
        if form is None:
            return Response(status_code=403)
        handle_status(client, form)
        return Response(status_code=204)

    @app.post("/twilio/sms/{client}")
    async def sms(client: str, request: Request):
        form = await _checked(request)
        if form is None:
            return Response(status_code=403)
        return _xml(R.inbound_sms(client, form))

    @app.on_event("startup")
    async def _sender():
        """Every 30 s: send approved texts (only with RECEPTION_SMS_LIVE=1; each is re-checked by the database)."""
        import asyncio

        async def loop():
            while True:
                try:
                    await asyncio.to_thread(R.send_pending)
                except Exception as e:
                    R.logger.warning("sender loop: %s", type(e).__name__)
                await asyncio.sleep(30)
        if _env().get("RECEPTION_SMS_LIVE") == "1":
            asyncio.get_event_loop().create_task(loop())

    @app.websocket("/twilio/media/{client}")
    async def media(websocket: WebSocket, client: str):
        await websocket.accept()
        import receptionist_voice
        await receptionist_voice.run_call(websocket, client)
