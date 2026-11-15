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
import collections
import datetime as dt
import hashlib
import hmac
import json
import math
import os
import re
import sys
import unicodedata

_INVISIBLE = re.compile("[​-‏⁠﻿‪-‮]")
_TRANS = str.maketrans("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹‐‑‒–—―−", "01234567890123456789" + "-" * 7)
_WS = "[ \t\n\r\f\v]"
_EXT = re.compile(_WS + r"*(ext\.?|extension|x|#)" + _WS + r"*[0-9]{1,6}\Z", re.I)
_TRUNK = ("44", "20", "33", "49", "61", "90", "971", "966", "212", "962", "961")
_BAD = re.compile(r"[^0-9+()\-." + " \t\n\r\f\v" + "]")


def normalize_phone(p):
    """'+<digits>' or None. Mirror of SQL public.normalize_phone: see the comment there for the rules (North American assumption for numbers without a plus sign)."""
    if p is None:
        return None
    t = unicodedata.normalize("NFKC", _INVISIBLE.sub("", p)).translate(_TRANS).strip(" ")
    t = _EXT.sub("", t)
    if t == "" or _BAD.search(t) or t.find("+") > 0 or t.count("+") > 1:
        return None
    paren0 = re.search(r"\(" + _WS + r"*0" + _WS + r"*\)", t) is not None
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
    # trunk prefix (review finding 4): see the SQL comment. Strip one 0 after the country code where it is a trunk prefix; ambiguous forms are None.
    if not d.startswith("1"):
        m = re.match(r"(971|966|212|962|961)", d) or re.match(r"(44|20|33|49|61|90)", d) or re.match(r"(351)", d) or re.match(r"(39|34)", d)
        cc = m.group(1) if m else None
        rest = d[len(cc):] if cc else None
        if cc in _TRUNK:
            if rest.startswith("00"):
                return None
            if rest.startswith("0"):
                d = cc + rest[1:]
            elif paren0:
                return None
        elif cc == "39":
            if paren0:
                return None
        elif cc in ("34", "351"):
            if paren0 or rest.startswith("0"):
                return None
        elif paren0:
            return None
        if len(d) < 8 or len(d) > 15:
            return None
    elif paren0:
        return None
    if d.startswith("1") and not re.fullmatch(r"1[2-9][0-9]{2}[2-9][0-9]{6}", d):
        return None
    return "+" + d


def hmac_hex(key: str, msg: str) -> str:
    return hmac.new(key.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).hexdigest()


def lp(field) -> str:
    """Length-prefixed field: '<byte length>:<field>'. Mirror of public.ffm_lp. With it a message can never be re-split at a ':' or '|' inside a field."""
    f = str(field)
    return f"{len(f.encode('utf-8'))}:{f}"


def key_fingerprint(key: str, name: str) -> str:
    return hmac_hex(key, "key|v1|" + lp(name))


def contact_mac(capture_key: str, kind: str, normalized: str) -> str:
    """Keyed hash that binds a capture to a contact. kind is 'email' or 'phone'. Domain 'con|v1|'."""
    return hmac_hex(capture_key, "con|v1|" + lp(kind) + lp(normalized))


def sup_message(kind: str, normalized: str) -> str:
    return "sup|v1|" + lp(kind) + lp(normalized)


def suppression_mac(suppression_key: str, kind: str, normalized: str) -> str:
    """Domain 'sup|v1|': distinct from the capture domain 'cap|v1|' so a suppression hash can never be a capture seal."""
    return hmac_hex(suppression_key, sup_message(kind, normalized))


def key_problem(value, other=None):
    """None when the key is acceptable, else a reason code. Mirror of public.ffm_key_problem (shared table sqltests/data/key_cases.tsv). Never put the key in a message."""
    if value is None:
        return "missing"
    n = len(value)
    if n < 32 or n > 200:
        return "length"
    cnt = collections.Counter(value)
    h = -sum((c / n) * math.log2(c / n) for c in cnt.values())
    if len(cnt) < 12 or h < 3.0 or max(cnt.values()) * 4 > n:
        return "low_entropy"
    pieces = collections.Counter(value[i:i + 8] for i in range(n - 7))
    if any(v > 1 for v in pieces.values()) or re.search(r"(.)\1{5}", value, re.S):
        return "repeated_pattern"
    for i in range(n - 7):
        o = ord(value[i])
        if all(ord(value[i + k]) == o + k for k in range(8)) or all(ord(value[i + k]) == o - k for k in range(8)):
            return "repeated_pattern"
    if other is not None:
        lv, lo = value.lower(), other.lower()
        if lv == lo or lo in lv or lv in lo or any(lv[i:i + 12] in lo for i in range(n - 11)):
            return "related_key"
    return None


def _epoch(at) -> int:
    if isinstance(at, (int, float)):
        return int(at)
    if isinstance(at, str):
        at = dt.datetime.fromisoformat(at.replace("Z", "+00:00"))
    if at.tzinfo is None:
        raise ValueError("captured_at must carry a time zone")
    return int(at.timestamp())


_REF_OK = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{2,99}\Z")


def capture_canonical(workspace_id, capture_ref, channel, wording_version, wording_sha256, captured_at, contact, artifact_sha256) -> str:
    """The exact text that is signed. Mirrors public.ffm_capture_canonical: 'cap|v1|' + length-prefixed fields (no field can be re-split)."""
    if not _REF_OK.match(str(capture_ref)):
        raise ValueError("capture_ref must be letters, digits, dot, underscore or hyphen (3-100 characters; no colon, no bar)")
    return "cap|v1|" + "".join(lp(f) for f in (str(workspace_id), capture_ref, channel, wording_version, wording_sha256.lower(), str(_epoch(captured_at)), contact, artifact_sha256.lower()))


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


def _check_key_cli(argv):
    """python3 hq_consent.py check-key [<other-key-env-name>]: reads the key from the environment variable CONSENT_KEY_CANDIDATE (and the other key from CONSENT_KEY_OTHER) and prints only a verdict."""
    why = key_problem(os.environ.get("CONSENT_KEY_CANDIDATE"), os.environ.get("CONSENT_KEY_OTHER") or None)
    print("key OK" if why is None else f"key REFUSED ({why})")
    return 0 if why is None else 1


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "check-key":
        sys.exit(_check_key_cli(sys.argv))
    elif len(sys.argv) == 2 and sys.argv[1] == "seal":
        key = os.environ.get("CONSENT_CAPTURE_KEY", "")
        if len(key) < 32:
            sys.exit("set CONSENT_CAPTURE_KEY (the capture signing key) in the environment")
        print(capture_seal(key, **json.load(sys.stdin)))
    else:
        sys.exit("usage: CONSENT_CAPTURE_KEY=... python3 hq_consent.py seal < capture.json   |   CONSENT_KEY_CANDIDATE=... [CONSENT_KEY_OTHER=...] python3 hq_consent.py check-key")
