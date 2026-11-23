"""Donna Receptionist v1: an AI receptionist for a client business. It answers calls, sends a missed-call text-back, books appointments and follows up.

Built by INTEGRATING, not writing a voice stack:
- Pipecat (BSD-2-Clause, pinned in requirements-receptionist.txt) runs the real-time voice agent over Twilio Media Streams (receptionist_voice.py).
- Twilio handles telephony and SMS through its official REST API.
- Cal.com handles booking (hosted API v2).
- The existing CRM (client_workspaces / ws_leads) and the existing CASL consent / suppression path are reused.

This module is the pure logic: client config, business hours, the turn logic used by demo-line mode, TwiML, the Twilio signature, SMS sending, Cal.com, the
per-call cost estimate. Database rules: migrations/20261206_donna_receptionist_v1.sql. Design: docs/architecture/DONNA_RECEPTIONIST_V1.md.

Governance:
- No live call and no text without the owner. Clients start in 'demo'.
- Every text is queued through reception_queue_sms. That function enforces the business name, "Reply STOP", the opt-outs and suppression list, the owner
  approval or his standing rule, and the daily ceiling. A text is sent only after reception_claim_sms returns it.
- There are no outbound calls. LLM calls go through hq_llm.complete with contains_client_data=True, because a caller's words are client data.
"""
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import json
import logging
import math
import os
import re
import urllib.parse
from xml.sax.saxutils import escape, quoteattr
from zoneinfo import ZoneInfo

logger = logging.getLogger(__name__)
DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "receptionist")
DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
REQUIRED = ("business_name", "timezone", "hours", "services", "faqs", "escalation_number", "booking", "voice")
PHONE = re.compile(r"^\+[1-9][0-9]{7,14}$")
STOP_LINE = "Reply STOP to opt out."
HUMAN = re.compile(r"\b(human|person|real person|someone|receptionist|manager|owner|staff|operator|emergency|urgent)\b", re.I)
BOOK = re.compile(r"\b(book|appointment|schedule|reserve|availability|available|opening|slot)\b", re.I)
PRICE = re.compile(r"\b(price|cost|how much|fee|rate|charge)\b", re.I)
HOURS_Q = re.compile(r"\b(hours|open|close|closing|opening time)\b", re.I)

# ESTIMATES (US$ list prices, Nov 2026; verify on twilio.com/pricing and the STT/TTS provider pages). CAD = USD x 1.40.
FX_CAD = 1.40
COST_USD = {"voice_inbound_min": 0.0085, "media_stream_min": 0.004, "gather_speech_15s": 0.02, "stt_min": {"whisper-local": 0.0, "deepgram": 0.0043},
            "tts_min": {"kokoro": 0.0, "twilio-say": 0.0}, "sms_segment": 0.0083, "sms_carrier_fee": 0.003, "number_month": 1.15, "llm_turn": 0.0}


class ReceptionError(Exception):
    pass


def _rpc_default(name: str, args: dict):
    import hq
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


# ------------------------------------------------------------------------------------------------------------------- client config
def template() -> dict:
    with open(os.path.join(DIR, "TEMPLATE.json")) as f:
        return json.load(f)


def validate(cfg: dict) -> dict:
    """Return cfg when it is usable; raise ReceptionError naming the first problem. The same keys are required by the database check."""
    if not isinstance(cfg, dict):
        raise ReceptionError("config must be an object")
    miss = [k for k in REQUIRED if k not in cfg]
    if miss:
        raise ReceptionError(f"config is missing {', '.join(miss)}")
    if not (2 <= len(str(cfg["business_name"])) <= 80):
        raise ReceptionError("business_name must be 2-80 characters")
    try:
        ZoneInfo(cfg["timezone"])
    except Exception:
        raise ReceptionError(f"unknown timezone {cfg['timezone']!r}")
    for d, spans in (cfg["hours"] or {}).items():
        if d not in DAYS:
            raise ReceptionError(f"hours: unknown day {d!r}")
        for a, b in spans:
            if not (re.fullmatch(r"[0-2][0-9]:[0-5][0-9]", a) and re.fullmatch(r"[0-2][0-9]:[0-5][0-9]", b) and a < b):
                raise ReceptionError(f"hours: bad span {a}-{b} on {d}")
    for s in cfg["services"]:
        if not s.get("name") or not isinstance(s.get("price_cents"), int) or s["price_cents"] < 0 or int(s.get("minutes") or 0) <= 0:
            raise ReceptionError(f"services: each needs name, price_cents >= 0 and minutes > 0 ({s!r})")
    for q in cfg["faqs"]:
        if not q.get("q") or not q.get("a"):
            raise ReceptionError("faqs: each needs q and a")
    if not PHONE.match(str(cfg["escalation_number"])):
        raise ReceptionError("escalation_number must be E.164 (+1...)")
    if (cfg["booking"] or {}).get("provider") not in ("calcom", "none"):
        raise ReceptionError("booking.provider must be calcom or none")
    if (cfg["booking"] or {}).get("provider") == "calcom" and not isinstance(cfg["booking"].get("event_type_ids"), dict):
        raise ReceptionError("booking.event_type_ids maps each service name to a Cal.com event type id")
    if (cfg["voice"] or {}).get("tts") not in ("kokoro", "twilio-say", "cartesia", "elevenlabs"):
        raise ReceptionError("voice.tts must be kokoro (default), twilio-say, cartesia or elevenlabs")
    return cfg


def is_open(cfg: dict, now: dt.datetime | None = None) -> bool:
    tz = ZoneInfo(cfg["timezone"])
    t = (now or dt.datetime.now(dt.timezone.utc)).astimezone(tz)
    hm = t.strftime("%H:%M")
    return any(a <= hm < b for a, b in (cfg["hours"].get(DAYS[t.weekday()]) or []))


def hours_text(cfg: dict) -> str:
    parts = []
    for d in DAYS:
        spans = cfg["hours"].get(d) or []
        parts.append(f"{d.title()} " + (", ".join(f"{a}-{b}" for a, b in spans) if spans else "closed"))
    return "; ".join(parts)


def _money(c: int) -> str:
    return f"${c / 100:,.2f}" if c % 100 else f"${c // 100:,}"


def system_prompt(cfg: dict) -> str:
    """The voice agent's instructions: facts come ONLY from the client's config; it never invents prices, never claims to be human."""
    svc = "; ".join(f"{s['name']}: {_money(s['price_cents'])}, {s['minutes']} min" for s in cfg["services"]) or "none listed"
    faq = " | ".join(f"Q: {q['q']} A: {q['a']}" for q in cfg["faqs"][:30]) or "none"
    return (f"You are the AI receptionist for {cfg['business_name']}. Say you are an AI assistant if asked or at the start. Be brief: one or two short sentences.\n"
            f"Hours: {hours_text(cfg)} ({cfg['timezone']}).\nServices and prices: {svc}.\nFAQ: {faq}\n"
            "Only use these facts. If you do not know, offer to take a message or connect the caller to a person. Never give medical, legal or financial advice. "
            "Never ask for card numbers, health details or ID numbers. To book, collect the service and a preferred time, then use the booking tool. "
            "If the caller asks for a person or it is urgent, use the transfer tool.")


# ------------------------------------------------------------------------------------------------------------------- turn logic (demo line + fallback)
def _faq(cfg: dict, text: str) -> str | None:
    words = set(re.findall(r"[a-z]{4,}", text.lower()))
    best, score = None, 0
    for q in cfg["faqs"]:
        s = len(words & set(re.findall(r"[a-z]{4,}", q["q"].lower())))
        if s > score:
            best, score = q["a"], s
    return best if score >= 1 else None


def turn(cfg: dict, said: str, *, now: dt.datetime | None = None, llm=None, history: list | None = None) -> dict:
    """One caller utterance -> {'say', 'action': None|'transfer'|'book'|'hangup'}. Rules first (free, predictable); the LLM only for what rules don't cover."""
    said = (said or "").strip()[:500]
    if not said:
        return {"say": f"Sorry, I didn't catch that. How can {cfg['business_name']} help?", "action": None}
    if HUMAN.search(said):
        if is_open(cfg, now):
            return {"say": "Of course, connecting you to a person now.", "action": "transfer"}
        return {"say": "We're closed right now, so I can take a message or book you in. Someone will call you back during business hours.", "action": None}
    if BOOK.search(said):
        return {"say": "I can help you book. Which service, and what day and time works for you?", "action": "book"}
    if PRICE.search(said):
        for s in cfg["services"]:
            if s["name"].lower() in said.lower():
                return {"say": f"{s['name']} is {_money(s['price_cents'])} and takes about {s['minutes']} minutes.", "action": None}
        if cfg["services"]:
            return {"say": "Our prices: " + "; ".join(f"{s['name']} {_money(s['price_cents'])}" for s in cfg["services"][:5]) + ".", "action": None}
    if HOURS_Q.search(said):
        return {"say": f"Our hours are {hours_text(cfg)}.", "action": None}
    a = _faq(cfg, said)
    if a:
        return {"say": a, "action": None}
    if llm:
        msgs = list(history or [])[-8:] + [{"role": "user", "content": said}]
        r = llm(system_prompt(cfg), msgs, division="donna", task_class="receptionist.turn", tier="small", max_output=120, contains_client_data=True)
        text = (r or {}).get("text") if isinstance(r, dict) else None
        if text:
            return {"say": text.strip()[:400], "action": None}
    return {"say": "I can take a message, book an appointment, or connect you to a person. Which would you like?", "action": None}


class Conversation:
    """One call's state: rules + optional LLM per turn, and a short booking flow (service -> pick one of 3 open slots -> book). Booking needs Cal.com
    configured for the client; otherwise the caller is offered the booking link by text (queued through the DB rules) or a message."""

    def __init__(self, cfg: dict, *, llm=None, calcom=None, now=None):
        self.cfg, self.llm, self.calcom, self.now = cfg, llm, calcom, now
        self.history: list[dict] = []
        self.state: dict = {}
        self.booking_ref: str | None = None

    def _service(self, said: str) -> dict | None:
        return next((s for s in self.cfg["services"] if s["name"].lower() in said.lower()), None)

    def handle(self, said: str) -> dict:
        said = (said or "").strip()[:500]
        st = self.state.get("stage")
        if st == "service":
            svc = self._service(said)
            if not svc:
                return self._say("Which service: " + ", ".join(s["name"] for s in self.cfg["services"][:5]) + "?", None)
            return self._offer(svc)
        if st == "slot":
            pick = _pick(said, self.state["slots"])
            if pick is None:
                return self._say("Please say first, second or third.", None)
            try:
                self.booking_ref = self.calcom.book(self.state["event_type"], pick, "Caller", self.cfg["timezone"], phone=self.state.get("phone"))
            except Exception as e:
                logger.warning("booking failed: %s", str(e)[:120])
                self.state = {}
                return self._say("Sorry, I couldn't complete the booking. I'll have someone call you back to confirm.", None)
            self.state = {}
            return self._say(f"You're booked for {_speak_time(pick, self.cfg['timezone'])}. You'll get a confirmation. Anything else?", "booked")
        r = turn(self.cfg, said, now=self.now, llm=self.llm, history=self.history)
        if r["action"] == "book":
            svc = self._service(said)
            if svc:
                return self._offer(svc)
            if self.calcom and self.cfg["booking"].get("provider") == "calcom" and self.cfg["services"]:
                self.state = {"stage": "service"}
            elif not (self.calcom and self.cfg["booking"].get("provider") == "calcom"):
                return self._say("I can't book directly on this line, but I'll text you our booking link, or take a message.", "send_link")
        self.history += [{"role": "user", "content": said}, {"role": "assistant", "content": r["say"]}]
        return {"say": r["say"], "action": r["action"]}

    def _offer(self, svc: dict) -> dict:
        ids = self.cfg["booking"].get("event_type_ids") or {}
        if not (self.calcom and svc["name"] in ids):
            self.state = {}
            return self._say(f"I'll text you our booking link for {svc['name']}, or someone can call you back.", "send_link")
        start = (self.now or dt.datetime.now(dt.timezone.utc))
        try:
            slots = self.calcom.slots(ids[svc["name"]], start.date().isoformat(), (start + dt.timedelta(days=7)).date().isoformat(), self.cfg["timezone"])[:3]
        except Exception:
            slots = []
        if not slots:
            self.state = {}
            return self._say(f"I don't see open times for {svc['name']} this week. Can I take a message for a call back?", None)
        self.state = {"stage": "slot", "slots": slots, "event_type": ids[svc["name"]]}
        opts = ", ".join(f"{w}: {_speak_time(x, self.cfg['timezone'])}" for w, x in zip(("first", "second", "third"), slots))
        return self._say(f"For {svc['name']} I have {opts}. Which one?", None)

    def _say(self, text: str, action):
        self.history.append({"role": "assistant", "content": text})
        return {"say": text, "action": action}


def _pick(said: str, slots: list[str]) -> str | None:
    s = said.lower()
    words = ("first", "second", "third")
    for i, w in enumerate(words):
        if i < len(slots) and w in s:
            return slots[i]
    for i in range(min(3, len(slots))):
        if re.search(rf"\b{i + 1}\b", s):
            return slots[i]
    return slots[0] if slots and re.fullmatch(r"(the )?one\W*", s.strip()) else None


def _speak_time(iso: str, tz: str) -> str:
    try:
        t = dt.datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(ZoneInfo(tz))
        return t.strftime("%A at %-I:%M %p").replace(":00 ", " ")
    except Exception:
        return iso


# ------------------------------------------------------------------------------------------------------------------- TwiML
def twiml_demo_greeting(cfg: dict, action_url: str) -> str:
    """Demo-line mode: Twilio <Gather input="speech"> turn by turn (no streaming server needed)."""
    hi = f"Hi, thanks for calling {cfg['business_name']}. I'm an AI assistant. How can I help?"
    return _gather(hi, action_url)


def _gather(say: str, action_url: str) -> str:
    return ('<?xml version="1.0" encoding="UTF-8"?><Response>'
            f'<Gather input="speech" action={quoteattr(action_url)} method="POST" speechTimeout="auto" language="en-CA"><Say>{escape(say)}</Say></Gather>'
            "<Say>Sorry, I didn't hear anything. Goodbye.</Say><Hangup/></Response>")


def twiml_turn(cfg: dict, said: str, action_url: str, conv: "Conversation | None" = None, **kw) -> tuple[str, dict]:
    r = conv.handle(said) if conv else turn(cfg, said, **kw)
    if r["action"] == "transfer":
        return ('<?xml version="1.0" encoding="UTF-8"?><Response>'
                f"<Say>{escape(r['say'])}</Say><Dial timeout=\"20\">{escape(cfg['escalation_number'])}</Dial></Response>"), r
    return _gather(r["say"], action_url), r


def twiml_stream(stream_url: str, client: str) -> str:
    """Live voice-agent mode: hand the call audio to the Pipecat server over Twilio Media Streams."""
    return ('<?xml version="1.0" encoding="UTF-8"?><Response><Connect>'
            f'<Stream url={quoteattr(stream_url)}><Parameter name="client" value={quoteattr(client)}/></Stream></Connect></Response>')


def twiml_not_in_service(cfg: dict | None = None) -> str:
    """A client that is not live (or Donna not active) and this is not the demo line: pass the call straight to the business (no AI answers it)."""
    if cfg and PHONE.match(str(cfg.get("escalation_number", ""))):
        return f'<?xml version="1.0" encoding="UTF-8"?><Response><Dial>{escape(cfg["escalation_number"])}</Dial></Response>'
    return '<?xml version="1.0" encoding="UTF-8"?><Response><Say>Sorry, this line is not in service.</Say><Hangup/></Response>'


def answer(client: str, form: dict, *, rpc=None, base_url: str, demo_number: str | None, stream: bool) -> str:
    """The /voice webhook: decide how this call is answered. Live AI only when the client is live (owner) and Donna is active; otherwise only the
    owner's demo line gets the AI (demo mode); anything else is passed straight to the business."""
    rpc = rpc or _rpc_default
    c = rpc("reception_client_config", {"p_slug": client})
    cfg = validate(c["config"])
    to = form.get("To") or ""
    rpc("reception_call_event", {"p_slug": client, "p_call_sid": form.get("CallSid"), "p_from": form.get("From"), "p_status": "in_progress"})
    if c.get("live") and to == c.get("twilio_number"):
        if stream:
            return twiml_stream(base_url.replace("https://", "wss://") + f"/twilio/media/{client}", client)
        return twiml_demo_greeting(cfg, f"{base_url}/twilio/turn/{client}")
    if demo_number and to == demo_number:
        return twiml_demo_greeting(cfg, f"{base_url}/twilio/turn/{client}")
    return twiml_not_in_service(cfg)


# ------------------------------------------------------------------------------------------------------------------- Twilio
def twilio_signature(auth_token: str, url: str, params: dict) -> str:
    s = url + "".join(k + str(params[k]) for k in sorted(params))
    return base64.b64encode(hmac.new(auth_token.encode(), s.encode(), hashlib.sha1).digest()).decode()


def verify_twilio(auth_token: str, url: str, params: dict, header: str | None) -> bool:
    if not auth_token or not header:
        return False
    return hmac.compare_digest(twilio_signature(auth_token, url, params), header)


def status_event(client: str, form: dict, *, rpc=None, cost=None) -> dict:
    """Twilio status callback -> call record; a missed call (no-answer / busy / short with no speech) is marked so a text-back can be queued."""
    rpc = rpc or _rpc_default
    st = form.get("CallStatus")
    dur = int(form.get("CallDuration") or 0)
    mapped = {"no-answer": "missed", "busy": "missed", "failed": "failed", "canceled": "missed"}.get(st, "completed" if st == "completed" else "in_progress")
    if st == "completed" and dur < 5 and form.get("AnsweredBy") != "human" and not form.get("SpeechHeard"):
        mapped = "missed"
    est = (cost or call_cost_cents)(dur / 60.0, mode="stream")
    return rpc("reception_call_event", {"p_slug": client, "p_call_sid": form.get("CallSid"), "p_from": form.get("From"), "p_status": mapped,
                                        "p_duration": dur, "p_cost_est_cents": est})


def text_back_body(cfg: dict) -> str:
    b = f"Hi, this is {cfg['business_name']}. Sorry we missed your call. Reply here or call back to book"
    if cfg["booking"].get("public_url"):
        b += f", or book online: {cfg['booking']['public_url']}"
    return f"{b}. {STOP_LINE}"[:320]


def queue_text_back(client_cfg: dict, call_sid: str, *, rpc=None) -> dict:
    rpc = rpc or _rpc_default
    return rpc("reception_queue_sms", {"p_call_sid": call_sid, "p_kind": "text_back", "p_body": text_back_body(client_cfg)})


def send_sms(message_id: str, *, rpc=None, http=None, env: dict | None = None) -> dict:
    """Send ONE approved text: claim (the DB re-checks consent / suppression / live / Donna active), Twilio REST, mark. Never sends on a refusal."""
    rpc, env = rpc or _rpc_default, (env if env is not None else os.environ)
    if env.get("RECEPTION_SMS_LIVE") != "1":
        return {"sent": False, "reason": "RECEPTION_SMS_LIVE is not 1 (owner switch on the server)"}
    sid, tok = env.get("TWILIO_ACCOUNT_SID") or "", env.get("TWILIO_AUTH_TOKEN") or ""
    if not (sid and tok):
        return {"sent": False, "reason": "Twilio credentials missing"}
    m = rpc("reception_claim_sms", {"p_id": message_id})
    if not isinstance(m, dict) or m.get("refused") or not m.get("to"):
        return {"sent": False, "reason": (m or {}).get("refused", "claim refused")}
    if http is None:
        import hq_hands_adapters
        http = hq_hands_adapters.http
    auth = base64.b64encode(f"{sid}:{tok}".encode()).decode()
    try:
        st, body, _ = http("POST", f"https://api.twilio.com/2010-04-01/Accounts/{urllib.parse.quote(sid)}/Messages.json",
                           headers={"Authorization": f"Basic {auth}"}, form={"To": m["to"], "From": m["from"], "Body": m["body"]})
    except Exception as e:
        rpc("reception_mark_sms", {"p_id": message_id, "p_ok": False, "p_provider_sid": None})
        return {"sent": False, "reason": f"twilio error {type(e).__name__}"}
    ok = st in (200, 201) and isinstance(body, dict) and re.fullmatch(r"SM[0-9a-f]{32}", str(body.get("sid", ""))) is not None
    rpc("reception_mark_sms", {"p_id": message_id, "p_ok": ok, "p_provider_sid": body.get("sid") if ok else None})
    return {"sent": ok} if ok else {"sent": False, "reason": f"twilio refused ({st})"}


def send_pending(*, rpc=None, http=None, env: dict | None = None, limit: int = 20) -> list[dict]:
    """The sender loop body: send each APPROVED text of a live client (the DB list); every one is re-checked by reception_claim_sms."""
    rpc, env = rpc or _rpc_default, (env if env is not None else os.environ)
    if env.get("RECEPTION_SMS_LIVE") != "1":
        return []
    return [dict(send_sms(i, rpc=rpc, http=http, env=env), message=i) for i in (rpc("reception_pending_sends", {"p_limit": int(limit)}) or [])]


def inbound_sms(client: str, form: dict, *, rpc=None) -> str:
    """Inbound text webhook: STOP (and the French words) withdraws consent through the existing CASL path. Replies with empty TwiML (Twilio's own
    opt-out confirmation applies on Canadian/US long codes)."""
    (rpc or _rpc_default)("reception_inbound_sms", {"p_slug": client, "p_from": form.get("From"), "p_body": form.get("Body"), "p_sid": form.get("MessageSid")})
    return '<?xml version="1.0" encoding="UTF-8"?><Response/>'


# ------------------------------------------------------------------------------------------------------------------- Cal.com (hosted API v2)
class CalCom:
    """Cal.com hosted API v2 (we call their API; we do not run or modify Cal.com, so its AGPL does not reach our code). Key: CALCOM_API_KEY."""
    BASE = "https://api.cal.com/v2"

    def __init__(self, api_key: str, http=None):
        if not api_key:
            raise ReceptionError("CALCOM_API_KEY missing")
        self.key, self._http = api_key, http

    def http(self, *a, **k):
        if self._http:
            return self._http(*a, **k)
        import hq_hands_adapters
        return hq_hands_adapters.http(*a, **k)

    def slots(self, event_type_id: int, start: str, end: str, tz: str) -> list[str]:
        q = urllib.parse.urlencode({"eventTypeId": int(event_type_id), "start": start, "end": end, "timeZone": tz})
        st, body, _ = self.http("GET", f"{self.BASE}/slots?{q}", headers={"Authorization": f"Bearer {self.key}", "cal-api-version": "2024-09-04"})
        if st != 200 or not isinstance(body, dict):
            raise ReceptionError(f"cal.com slots refused ({st})")
        out = []
        for day in sorted((body.get("data") or {}).values(), key=lambda v: str(v)):
            for s in day or []:
                out.append(s.get("start") if isinstance(s, dict) else s)
        return [x for x in out if x][:20]

    def book(self, event_type_id: int, start: str, name: str, tz: str, phone: str | None = None, email: str | None = None) -> str:
        attendee = {"name": (name or "Caller")[:80], "timeZone": tz}
        if email:
            attendee["email"] = email
        if phone:
            attendee["phoneNumber"] = phone
        st, body, _ = self.http("POST", f"{self.BASE}/bookings", headers={"Authorization": f"Bearer {self.key}", "cal-api-version": "2024-08-13"},
                                json_body={"start": start, "eventTypeId": int(event_type_id), "attendee": attendee})
        if st not in (200, 201) or not isinstance(body, dict) or not (body.get("data") or {}).get("uid"):
            raise ReceptionError(f"cal.com booking refused ({st})")
        return "cal:" + re.sub(r"[^A-Za-z0-9._-]", "", str(body["data"]["uid"]))[:100]


# ------------------------------------------------------------------------------------------------------------------- cost
def call_cost_cents(minutes: float, mode: str = "stream", stt: str = "whisper-local", tts: str = "kokoro", turns: int | None = None) -> int:
    """ESTIMATED CAD cents for one inbound call. stream = Pipecat over Media Streams; gather = demo-line mode (Twilio speech recognition per turn)."""
    m = max(minutes, 0.0)
    usd = m * COST_USD["voice_inbound_min"]
    if mode == "stream":
        usd += m * (COST_USD["media_stream_min"] + COST_USD["stt_min"].get(stt, 0.0043) + COST_USD["tts_min"].get(tts, 0.015))
    else:
        usd += (turns if turns is not None else max(1, math.ceil(m * 2))) * COST_USD["gather_speech_15s"]
    return int(math.ceil(usd * FX_CAD * 100))


def sms_cost_cents(segments: int = 1) -> int:
    return int(math.ceil(segments * (COST_USD["sms_segment"] + COST_USD["sms_carrier_fee"]) * FX_CAD * 100))


def report_text(rpc=None) -> str:
    try:
        rows = (rpc or _rpc_default)("reception_report", {}) or []
    except Exception as e:
        return f"Receptionist: report unavailable ({type(e).__name__})."
    if not rows:
        return "Receptionist: no clients yet (ops/OWNER_RECEPTIONIST.sql)."
    lines = ["Donna Receptionist (7 days; costs are estimates)"]
    for r in rows:
        lines.append(f"- {r['client']} [{r['status']}]: {r['calls_7d']} calls, {r['missed_7d']} missed, {r['booked_7d']} booked, {r['minutes_7d']} min, "
                     f"~${int(r['cost_est_cents_7d']) / 100:,.2f}; texts {r['texts_sent_7d']} sent, {r['texts_pending']} waiting for you"
                     + ("" if r["text_back"] else "; text-back off"))
    return "\n".join(lines)
