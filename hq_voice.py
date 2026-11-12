"""Voice notes in (Telegram voice -> text). Dormant until OPENAI_API_KEY is set on the bot; nothing else changes.
Short notes only (cost is a fraction of a cent per minute). The transcript goes through the same owner-only chat as typed text."""
from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request
import uuid

logger = logging.getLogger(__name__)
API = "https://api.openai.com/v1/audio/transcriptions"
MAX_SECONDS = 180
MAX_BYTES = 10_000_000
MODEL_LABEL = "whisper-1"      # label recorded at the spend gateway (flat per-minute price, no token estimate)
USD_PER_MINUTE = 0.006
FX_CONSERVATIVE = 1.5          # CAD per USD, deliberately high so the reservation over- rather than under-states cost


def estimate_cents(seconds) -> int:
    """CAD cents to reserve at the spend gateway BEFORE the provider is called. Unknown length is priced as the maximum."""
    s = float(seconds or 0)
    s = MAX_SECONDS if s <= 0 else min(s, MAX_SECONDS)
    return max(1, int(-(-(s / 60.0 * USD_PER_MINUTE * FX_CONSERVATIVE * 100) // 1)))


def configured() -> bool:
    return bool(os.environ.get("OPENAI_API_KEY"))


def too_long(seconds, size) -> str | None:
    if (seconds or 0) > MAX_SECONDS:
        return f"That voice note is over {MAX_SECONDS // 60} minutes. Send a shorter one or type it."
    if (size or 0) > MAX_BYTES:
        return "That voice note is too large. Send a shorter one."
    return None


def _multipart(fields: dict, filename: str, data: bytes, mime: str) -> tuple[bytes, str]:
    b = uuid.uuid4().hex
    parts = []
    for k, v in fields.items():
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    parts.append(f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\nContent-Type: {mime}\r\n\r\n'.encode() + data + b"\r\n")
    parts.append(f"--{b}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={b}"


def transcribe(data: bytes, filename: str = "voice.ogg", mime: str = "audio/ogg") -> str | None:
    """-> transcript, or None on any failure (the caller says so plainly). Never raises."""
    if not configured() or not data or len(data) > MAX_BYTES:
        return None
    body, ctype = _multipart({"model": os.environ.get("TRANSCRIBE_MODEL", "whisper-1"), "response_format": "json"}, filename, data, mime)
    req = urllib.request.Request(API, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {os.environ['OPENAI_API_KEY']}")
    req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            text = (json.loads(r.read()) or {}).get("text", "")
    except Exception as e:
        logger.warning("transcription failed: %s", type(e).__name__)
        return None
    text = (text or "").strip()
    return text[:4000] or None
