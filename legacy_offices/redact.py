"""Redaction for anything the legacy offices show, store or send to a model: secrets first, then personal data (emails, phones, street
addresses, postal codes, URLs with query strings). A tripwire, not a proof: what goes to a free model is ALSO checked by hq_llm's own
client-data routing (route_class / pii_hit), which refuses a prompt that still looks personal.
"""
from __future__ import annotations

import re

SECRET = [
    re.compile(r"\b(sk|rk|pk)-[A-Za-z0-9_-]{12,}"),                     # provider keys (sk-..., sk-ant-...)
    re.compile(r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),   # JWTs (Supabase keys)
    re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{30,}"),                       # Telegram bot tokens
    re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)\b([A-Z0-9_]*(KEY|TOKEN|SECRET|PASS|PASSWORD|AUTH)[A-Z0-9_]*)\s*[=:]\s*['\"]?[^\s'\"]{4,}"),
    re.compile(r"\bKEY[0-9A-Za-z]{20,}\b"),                              # Telnyx style keys
]
PERSONAL = [
    re.compile(r"[\w.+-]+@[\w-]+(\.[\w-]+)+"),
    re.compile(r"(?<![\w-])\+?1?[ .-]?\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}(?![\w-])"),
    re.compile(r"(?i)\b\d{1,6}\s+([A-Z][\w'.-]*\s+){0,4}(st|street|ave|avenue|rd|road|dr|drive|blvd|cres|crescent|crt|court|way|lane|ln|pl|place|hwy|highway|trail|tr)\b\.?"),
    re.compile(r"(?i)\b[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z][ -]?\d[ABCEGHJ-NPRSTV-Z]\d\b"),   # Canadian postal codes
    re.compile(r"https?://[^\s?#]+\?[^\s]+"),
]


def text(s: str, personal: bool = True) -> str:
    out = str(s or "")
    for rx in SECRET:
        out = rx.sub("[secret]", out)
    if personal:
        for rx in PERSONAL:
            out = rx.sub("[redacted]", out)
    return out


def looks_private(s: str) -> bool:
    """True if anything personal or secret is still in the text."""
    s = str(s or "")
    return any(rx.search(s) for rx in SECRET + PERSONAL)
