"""
Channel adapters for messages to the Chairman. Telegram text is the primary channel for everything.

  telegram        LIVE path: queues an owner_messages row; hq.deliver_owner_messages sends it (quiet hours applied by hq_core.send_owner).
  whatsapp        WhatsApp Business Cloud API (official Meta Graph API), text only. DISABLED until JARVIS_WHATSAPP=1, the env vars below are set and the owner
                  switches jarvis_core_config.whatsapp_enabled on. Env: WHATSAPP_ACCESS_TOKEN, WHATSAPP_PHONE_NUMBER_ID, WHATSAPP_OWNER_NUMBER.
                  Business-initiated messages outside the 24-hour customer-service window need an approved message template (WHATSAPP_TEMPLATE).
  emergency_call  A phone call through a telephony provider's official API (Twilio Programmable Voice) that speaks a short scripted alert and tells the
                  Chairman to check Telegram. ONLY for the events in ops/CRITICAL_EVENTS.json (protected). The DATABASE enforces: off by default, at most
                  max_calls_per_day (default 2), one call per dedupe key per 24 h, every decision logged (jarvis_call_allowed / jarvis_call_result).
                  DISABLED until JARVIS_EMERGENCY_CALL=1, the env vars are set and the owner switches emergency_call_enabled on.
                  Env: TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER, OWNER_PHONE_NUMBER.
  voice           Real-time two-way voice conversation: INTERFACE ONLY (VoiceConversation below). No vendor is called; nothing is wired.

Encryption, stated honestly: Telegram bot chats are NOT end-to-end encrypted (client-server encryption; Telegram's servers can read them).
The WhatsApp Business Cloud API is encrypted in transit, but messages are processed on Meta's servers: NOT end-to-end like a person-to-person WhatsApp chat.
A phone call through a telephony provider is NOT end-to-end encrypted. So none of these channels carries secrets or client personal data.
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from typing import Iterable, Iterator, Protocol

import hq

logger = logging.getLogger(__name__)
ROOT = os.path.dirname(os.path.abspath(__file__))
GRAPH = "https://graph.facebook.com/v21.0"          # confirm the current Graph API version at activation


def _http(method: str, url: str, data: bytes | None, headers: dict, timeout: int = 20) -> dict:
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in headers.items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}


def _config() -> dict:
    try:
        return (hq._request("POST", "/rest/v1/rpc/jarvis_core_status", {}) or {}).get("config") or {}
    except Exception:
        return {}


class Channel:
    name = "base"

    def enabled(self) -> bool:
        return False

    def send(self, text: str, urgency: str = "normal", kind: str | None = None) -> dict:
        raise NotImplementedError


class TelegramChannel(Channel):
    name = "telegram"

    def enabled(self) -> bool:
        return hq.hq_enabled()

    def send(self, text, urgency="normal", kind=None):
        import hq_core
        row = hq_core.send_owner(text, urgency=urgency, kind=kind)
        return {"ok": True, "channel": self.name, "held_until": row.get("deliver_after")}


class WhatsAppChannel(Channel):
    name = "whatsapp"

    def __init__(self, env=None, http=_http, config=_config):
        self.env, self.http, self.config = (os.environ if env is None else env), http, config

    def missing(self) -> list[str]:
        return [n for n in ("WHATSAPP_ACCESS_TOKEN", "WHATSAPP_PHONE_NUMBER_ID", "WHATSAPP_OWNER_NUMBER") if not self.env.get(n)]

    def enabled(self) -> bool:
        return self.env.get("JARVIS_WHATSAPP") == "1" and not self.missing() and bool(self.config().get("whatsapp_enabled"))

    def send(self, text, urgency="normal", kind=None):
        if not self.enabled():
            return {"ok": False, "channel": self.name, "reason": "disabled"}
        import hq_core
        to = re.sub(r"[^0-9]", "", self.env["WHATSAPP_OWNER_NUMBER"])
        tpl = self.env.get("WHATSAPP_TEMPLATE")
        body = ({"messaging_product": "whatsapp", "to": to, "type": "template", "template": {"name": tpl, "language": {"code": "en"},
                 "components": [{"type": "body", "parameters": [{"type": "text", "text": hq_core.address(text)[:1000]}]}]}} if tpl else
                {"messaging_product": "whatsapp", "to": to, "type": "text", "text": {"preview_url": False, "body": hq_core.address(text)[:4096]}})
        try:
            r = self.http("POST", f"{GRAPH}/{self.env['WHATSAPP_PHONE_NUMBER_ID']}/messages", json.dumps(body).encode(),
                          {"Authorization": f"Bearer {self.env['WHATSAPP_ACCESS_TOKEN']}", "Content-Type": "application/json"})
        except urllib.error.HTTPError as e:
            return {"ok": False, "channel": self.name, "reason": f"HTTP {e.code}"}
        except Exception as e:
            return {"ok": False, "channel": self.name, "reason": type(e).__name__}
        return {"ok": True, "channel": self.name, "id": ((r.get("messages") or [{}])[0]).get("id")}


def load_criteria(path: str | None = None) -> dict:
    with open(path or os.path.join(ROOT, "ops", "CRITICAL_EVENTS.json"), encoding="utf-8") as f:
        return json.load(f)


class EmergencyCall(Channel):
    """call(event, dedupe) -> result. Never raises. The script names the event and says: check Telegram."""
    name = "emergency_call"
    REQUIRED = ("TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM_NUMBER", "OWNER_PHONE_NUMBER")

    def __init__(self, env=None, http=_http, rpc=None, criteria=None):
        self.env, self.http = (os.environ if env is None else env), http
        self.rpc = rpc or (lambda name, args: hq._request("POST", f"/rest/v1/rpc/{name}", args))
        self.criteria = criteria if criteria is not None else load_criteria()

    def missing(self):
        return [n for n in self.REQUIRED if not self.env.get(n)]

    def enabled(self) -> bool:
        return self.env.get("JARVIS_EMERGENCY_CALL") == "1" and not self.missing()

    def script(self, event: str) -> str:
        says = self.criteria["events"][event]["says"]
        return self.criteria["script"].format(says=says)

    def send(self, text, urgency="normal", kind=None):
        return {"ok": False, "channel": self.name, "reason": "use call(event, dedupe): calls are for listed critical events only"}

    def call(self, event: str, dedupe: str, severity: str = "critical") -> dict:
        try:
            return self._call(event, dedupe, severity)
        except Exception as e:          # documented: never raises (Telegram already carries the alert)
            logger.warning("emergency call failed before the vendor: %s", type(e).__name__)
            return {"ok": False, "outcome": "error", "reason": type(e).__name__}

    def _call(self, event: str, dedupe: str, severity: str) -> dict:
        """The DATABASE decides (jarvis_call_allowed checks its own copy of the criteria; criteria_ok below is only the adapter's opinion and is ignored there)."""
        ev = (self.criteria.get("events") or {}).get(event)
        criteria_ok = bool(ev) and severity == "critical" and ev.get("min_severity") == "critical"
        key = hashlib.sha256(f"{event}|{dedupe}".encode()).hexdigest()[:40]
        try:
            gate = self.rpc("jarvis_call_allowed", {"p_event_kind": event if re.fullmatch(r"[a-z][a-z_]{2,40}", event or "") else "unknown_event",
                                                    "p_dedupe": key, "p_criteria_ok": criteria_ok}) or {}
        except Exception as e:
            return {"ok": False, "outcome": "refused_unreachable", "reason": type(e).__name__}     # cannot record it: no call (Telegram still carries the alert)
        if not gate.get("allowed"):
            return {"ok": False, "outcome": gate.get("outcome")}
        if not ev:                       # the database allowed an event this file does not list: the two lists differ; place no call
            self._result(key, "failed", {"reason": "event not in ops/CRITICAL_EVENTS.json"})
            return {"ok": False, "outcome": "failed", "reason": "criteria lists differ"}
        if not self.enabled():
            self._result(key, "dry_run", {"reason": "env not set up", "missing": self.missing()})
            return {"ok": False, "outcome": "dry_run", "missing": self.missing()}
        sid = self.env["TWILIO_ACCOUNT_SID"]
        twiml = "<Response><Say voice=\"alice\">" + _xml(self.script(event)) + "</Say></Response>"
        data = urllib.parse.urlencode({"To": self.env["OWNER_PHONE_NUMBER"], "From": self.env["TWILIO_FROM_NUMBER"], "Twiml": twiml}).encode()
        auth = base64.b64encode(f"{sid}:{self.env['TWILIO_AUTH_TOKEN']}".encode()).decode()
        try:
            r = self.http("POST", f"https://api.twilio.com/2010-04-01/Accounts/{sid}/Calls.json", data,
                          {"Authorization": f"Basic {auth}", "Content-Type": "application/x-www-form-urlencoded"})
        except Exception as e:
            self._result(key, "failed", {"reason": type(e).__name__})
            return {"ok": False, "outcome": "failed"}
        self._result(key, "placed", {"call": str(r.get("sid") or "")[:40]})
        return {"ok": True, "outcome": "placed"}

    def _result(self, key, outcome, detail):
        try:
            self.rpc("jarvis_call_result", {"p_dedupe": key, "p_outcome": outcome, "p_detail": detail})
        except Exception:
            logger.warning("call result not recorded")


def _xml(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


# ------------------------------------------------------------------------------------------------------------------- real-time voice (design only)
class SpeechToText(Protocol):
    def stream(self, audio_chunks: Iterable[bytes]) -> Iterator[str]: ...          # partial and final transcripts


class TextToSpeech(Protocol):
    def stream(self, text_chunks: Iterable[str]) -> Iterator[bytes]: ...          # audio frames, starts before the text is complete


class VoiceConversation(Channel):
    """Future channel: real-time two-way voice. Pipeline per turn, all streaming:
         caller audio -> SpeechToText.stream -> (end of utterance) -> hq_llm.complete (same gateway, same rules, identity says "sir")
         -> sentence chunks -> TextToSpeech.stream -> audio back to the call.
    Barge-in: new caller audio cancels the TTS stream. Budget: every turn is a metered call; a session has a turn and minute cap.
    Transport: a telephony media stream or WebRTC; NOT end-to-end encrypted (the provider and our server hear the audio).
    DISABLED: no vendor is chosen and nothing calls a vendor. Implementations plug in stt / tts objects at activation."""
    name = "voice"

    def __init__(self, stt: SpeechToText | None = None, tts: TextToSpeech | None = None):
        self.stt, self.tts = stt, tts

    def enabled(self) -> bool:
        return False

    def send(self, text, urgency="normal", kind=None):
        return {"ok": False, "channel": self.name, "reason": "design only: not implemented"}

    def converse(self, audio_chunks):
        raise NotImplementedError("real-time voice is design-only until the owner chooses and approves a vendor")


def get(name: str) -> Channel:
    return {"telegram": TelegramChannel, "whatsapp": WhatsAppChannel, "voice": VoiceConversation}[name]()
