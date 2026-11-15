"""Consent-integrity helpers shared by the bot, the backup code and the form-ingest side. STDLIB ONLY (the consent form endpoint can copy this one file).

Nothing here sends anything or authorizes outreach. It mirrors three pieces of SQL so they can be tested against each other:
  normalize_phone(p)         == public.normalize_phone(p)        (migrations/20261121_consent_evidence_v1.sql)
  hmac_hex(key, msg)         == public.ffm_hmac_sha256(key, msg)
  capture_canonical/seal     == public.ffm_capture_canonical + the seal check in public.ffm_ingest_capture
  suppression_digest(macs)   == the count/hash that public.backup_suppression_export() and ffm_suppression_digest() report

Evidence model in one paragraph: express consent counts only if evidence_ref names a registered CAPTURE. A form endpoint registers a capture by calling ffm_ingest_capture
with a seal = HMAC-SHA256(capture signing key, canonical text). The key is held by the owner and the form endpoint; the bot does not have it, so the bot cannot mint a
valid capture. See DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 4. CLI for the form side (the key comes from the environment, never an argument):

  CONSENT_CAPTURE_KEY=... python3 hq_consent.py seal < capture.json      # prints the seal; capture.json holds the ffm_ingest_capture arguments
"""
import datetime as dt
import hashlib
import hmac
import json
import os
import re
import sys
import unicodedata

_INVISIBLE = re.compile("[​-‏⁠﻿‪-‮]")
_TRANS = str.maketrans("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹‐‑‒–—―−", "01234567890123456789" + "-" * 7)
_WS = "[ \t\n\r\f\v]"
_EXT = re.compile(_WS + r"*(ext\.?|extension|x|#)" + _WS + r"*[0-9]{1,6}\Z", re.I)
_BAD = re.compile(r"[^0-9+()\-." + " \t\n\r\f\v" + "]")


def normalize_phone(p):
    """'+<digits>' or None. Mirror of SQL public.normalize_phone: see the comment there for the rules (North American assumption for numbers without a plus sign)."""
    if p is None:
        return None
    t = unicodedata.normalize("NFKC", _INVISIBLE.sub("", p)).translate(_TRANS).strip(" ")
    t = _EXT.sub("", t)
    if t == "" or _BAD.search(t) or t.find("+") > 0 or t.count("+") > 1:
        return None
    d = re.sub(r"[^0-9]", "", t)
    if t.startswith("+"):
        pass
    elif d.startswith("00"):
        d = d[2:]
    elif re.fullmatch(r"[2-9][0-9]{9}", d):
        d = "1" + d
    elif re.fullmatch(r"1[0-9]{10}", d):
        pass
    else:
        return None
    if d.startswith("0") or len(d) < 8 or len(d) > 15:
        return None
    if d.startswith("1") and not re.fullmatch(r"1[2-9][0-9]{2}[2-9][0-9]{6}", d):
        return None
    return "+" + d


def hmac_hex(key: str, msg: str) -> str:
    return hmac.new(key.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).hexdigest()


def key_fingerprint(key: str, name: str) -> str:
    return hmac_hex(key, "fendezy-key-check-v1:" + name)


def contact_mac(capture_key: str, kind: str, normalized: str) -> str:
    """Keyed hash that binds a capture to a contact. kind is 'email' or 'phone'."""
    return hmac_hex(capture_key, f"contact|{kind}:{normalized}")


def suppression_mac(suppression_key: str, kind: str, normalized: str) -> str:
    return hmac_hex(suppression_key, f"{kind}:{normalized}")


def _epoch(at) -> int:
    if isinstance(at, (int, float)):
        return int(at)
    if isinstance(at, str):
        at = dt.datetime.fromisoformat(at.replace("Z", "+00:00"))
    if at.tzinfo is None:
        raise ValueError("captured_at must carry a time zone")
    return int(at.timestamp())


def capture_canonical(workspace_id, capture_ref, channel, wording_version, wording_sha256, captured_at, contact, artifact_sha256) -> str:
    """The exact text that is signed. Mirrors public.ffm_capture_canonical."""
    for f in (capture_ref, wording_version, contact):
        if "|" in str(f):
            raise ValueError("a capture field may not contain '|'")
    return "|".join(["ffm-capture-v1", str(workspace_id), capture_ref, channel, wording_version, wording_sha256.lower(), str(_epoch(captured_at)), contact, artifact_sha256.lower()])


def capture_seal(capture_key: str, **fields) -> str:
    return hmac_hex(capture_key, capture_canonical(**fields))


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# ---- suppression export (what backup_suppression_export() returns and the backup file carries) ------------------------------------------------------------------------
def suppression_lines(macs) -> list:
    return sorted(f"{k}:{m}" for k, m in macs)


def suppression_digest(macs) -> dict:
    lines = suppression_lines(macs)
    return {"count": len(lines), "email_count": sum(1 for x in lines if x.startswith("email:")), "phone_count": sum(1 for x in lines if x.startswith("phone:")),
            "hash": hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()}


def validate_suppression_export(exp) -> list:
    """Problems with an export (empty list = well-formed and self-consistent). Never raises. Does not check the key (only the database holds it)."""
    if not isinstance(exp, dict) or exp.get("version") != 1:
        return ["not a version 1 suppression export"]
    if exp.get("included") is not True:
        return ["export says it holds no list: " + str(exp.get("reason", "?"))[:120]]
    macs, probs = exp.get("macs"), []
    if not isinstance(macs, list):
        return ["macs is not a list"]
    seen = set()
    for e in macs:
        if not (isinstance(e, list) and len(e) == 2 and e[0] in ("email", "phone") and isinstance(e[1], str) and re.fullmatch(r"[0-9a-f]{64}", e[1])):
            return ["malformed entry in macs"]
        if (e[0], e[1]) in seen:
            probs.append("duplicate entry")
        seen.add((e[0], e[1]))
    d = suppression_digest(seen)
    for k in ("count", "email_count", "phone_count", "hash"):
        if exp.get(k) != d[k]:
            probs.append(f"{k} does not match the list")
    if not (isinstance(exp.get("key_check"), str) and re.fullmatch(r"[0-9a-f]{64}", exp["key_check"])):
        probs.append("key_check missing")
    return probs


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "seal":
        key = os.environ.get("CONSENT_CAPTURE_KEY", "")
        if len(key) < 32:
            sys.exit("set CONSENT_CAPTURE_KEY (the capture signing key) in the environment")
        print(capture_seal(key, **json.load(sys.stdin)))
    else:
        sys.exit("usage: CONSENT_CAPTURE_KEY=... python3 hq_consent.py seal < capture.json")
