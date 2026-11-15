"""Client-data scrubber for text the ENGINE stores in tables that are exported off-site (tasks.result, escalations.summary, agent_runs.summary).

Why: researcher / outreach output carries prospect names, published emails, phone numbers and personal profile URLs. The database export (public.backup_redact_text,
migration 20261120_backup_redact_leak_paths_v1) is the SECOND layer; this module is the FIRST: the text is scrubbed before it is stored, so the live row never holds
more client contact data than it needs. The engine still uses the RAW model output for what it must (lead capture, drafts, facts, valuations): only the copy stored in
tasks.result / escalations.summary is scrubbed. Same rules as the SQL redactor (a port, kept in step by test_hq_scrub.py), LIGHT mode:
  emails (plain, spaced, "[at]/[dot]", arobase/point), phone numbers (all separator styles, +1, Arabic-Indic/fullwidth digits, spelled-out digits), runs of 7+ digits,
  URLs with personal paths, base64/hex blobs that decode to any of those, and the names / emails / phones of known clients (leads, setters, ws_leads, client workspaces).
Fail closed on errors: an exception while scrubbing returns the marker, never the raw text. Pure standard library; the known-client list is fetched through a callable the engine passes.
LIMITS: it cannot know a name that is not in the database, misspellings, leetspeak, or base32; a letter-spaced known name is flagged ("uncertain") instead of located."""
import base64
import binascii
import html
import logging
import re
import threading
import time
import unicodedata
import urllib.parse

logger = logging.getLogger(__name__)

UNCERTAIN = "[redacted:uncertain]"
_FROM = "аеорсхуіјѕһԁԛԝкмтнвѵɡӏոսАВЕКМНОРСТХУІЈЅҮѠԌԚԜᎪᏟαονρτικυχεγημωςβΑΒΕΖΗΙΚΜΝΟΡΤΥΧϹͿàÀáÁâÂãÃäÄåÅāĀăĂąĄǎǍǟǞǡǠǻǺȁȀȃȂȧȦçÇćĆĉĈċĊčČďĎđĐèÈéÉêÊëËēĒĕĔėĖęĘěĚȅȄȇȆȩȨĝĜğĞġĠģĢǧǦĥĤħĦìÌíÍîÎïÏĩĨīĪĭĬįĮıǐǏȉȈȋȊĵĴķĶĺĹļĻľĽŀĿłŁñÑńŃņŅňŇŉòÒóÓôÔõÕöÖøØōŌŏŎőŐǒǑǫǪȍȌȏȎȯȮŕŔŗŖřŘȑȐȓȒśŚŝŜşŞšŠșȘţŢťŤŧŦțȚùÙúÚûÛüÜũŨūŪŭŬůŮűŰųŲǔǓȕȔȗȖŵŴýÝÿŸŷŶźŹżŻžŽßœŒæÆðÐþÞĳ٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹०१२३४५६७८९০১২৩৪৫৬৭৮৯੦੧੨੩੪੫੬੭੮੯૦૧૨૩૪૫૬૭૮૯୦୧୨୩୪୫୬୭୮୯௦௧௨௩௪௫௬௭௮௯౦౧౨౩౪౫౬౭౮౯೦೧೨೩೪೫೬೭೮೯൦൧൨൩൪൫൬൭൮൯๐๑๒๓๔๕๖๗๘๙໐໑໒໓໔໕໖໗໘໙༠༡༢༣༤༥༦༧༨༩၀၁၂၃၄၅၆၇၈၉០១២៣៤៥៦៧៨៩᠐᠑᠒᠓᠔᠕᠖᠗᠘᠙"
_TO = "aeopcxyijshdqwkmthbvglnuABEKMHOPCTXYIJSYWGQWACaovptikuxeynuwsbABEZHIKMNOPTYXCJaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAcCcCcCcCcCdDdDeEeEeEeEeEeEeEeEeEeEeEeEgGgGgGgGgGhHhHiIiIiIiIiIiIiIiIiiIiIiIjJkKlLlLlLlLlLnNnNnNnNnoOoOoOoOoOoOoOoOoOoOoOoOoOoOrRrRrRrRrRsSsSsSsSsStTtTtTtTuUuUuUuUuUuUuUuUuUuUuUuUuUwWyYyYyYzZzZzZsoOaAdDpPi01234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
_TABLE = str.maketrans(dict(zip(_FROM, _TO)))
_INVISIBLE = re.compile("[­͏؜ᅟᅠ឴឵᠋-᠎​-‏‪-‮⁠-⁯ㅤ︀-️﻿ﾠ-]")
_MARKS = re.compile("[̀-ͯ᪰-᫿᷀-᷿⃐-⃿︠-︯]")
STOP = frozenset("""the and for inc ltd llc corp company group services service solutions ottawa canada ontario toronto barrhaven kanata home homes real estate realty mortgage mortgages insurance
plumbing heating cooling electric electrical roofing construction contracting contractors cleaning renovation renovations design studio law legal dental care auto detailing energy les des pour avec
management consulting marketing agency store shop ltee cie enr com www http https setter setters lead leads payout payouts deal deals close closed owner client clients public task tasks note notes
salon salons flood test demo sample""".split())

_NAMED = {"&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&apos;": "'", "&nbsp;": " ", "&commat;": "@", "&period;": ".", "&colon;": ":", "&sol;": "/", "&lpar;": "(", "&rpar;": ")",
          "&lsqb;": "[", "&rsqb;": "]", "&lbrack;": "[", "&rbrack;": "]", "&lcub;": "{", "&rcub;": "}", "&plus;": "+", "&comma;": ",", "&hyphen;": "-", "&dash;": "-", "&lowbar;": "_",
          "&num;": "#", "&semi;": ";", "&excl;": "!", "&percnt;": "%", "&equals;": "=", "&quest;": "?"}


def fold(text: str) -> str:
    t = unicodedata.normalize("NFKC", text)
    t = unicodedata.normalize("NFD", t)
    t = _INVISIBLE.sub("", t)
    t = _MARKS.sub("", t)
    return t.translate(_TABLE)


def unescape(t: str) -> str:
    def pct(m):
        try:
            return urllib.parse.unquote(m.group(0), errors="strict")
        except Exception:
            return m.group(0)
    t = re.sub(r"(?:%[0-9a-fA-F]{2})+", pct, t)

    def num(m):
        try:
            n = int(m.group(1), 16) if m.group(1)[:1] in "xX" else int(m.group(1))
            return chr(n) if 1 <= n <= 0x10FFFF and not 0xD800 <= n <= 0xDFFF else m.group(0)
        except Exception:
            return m.group(0)
    t = re.sub(r"&#([xX][0-9a-fA-F]{1,6}|[0-9]{1,7});?", num, t)
    for k, v in _NAMED.items():
        t = t.replace(k, v)

    def esc(m):
        try:
            return chr(int(m.group(1) or m.group(2), 16))
        except Exception:
            return m.group(0)
    return re.sub(r"\\u([0-9a-fA-F]{4})|\\x([0-9a-fA-F]{2})", esc, t)


def _normalise(text: str) -> str:
    t = fold(text)
    for _ in range(4):
        nxt = fold(unescape(t))
        if nxt == t:
            break
        t = nxt
    return t


_URL = re.compile(r"(?:https?://|www\.)[^\s<>\"')\]]+", re.I)
_PERSONAL_URL = re.compile(r"linkedin\.com/(?:in|pub|profile|sales/people)/|facebook\.com/(?!pages/|groups/|events/|business/|marketplace/)[^/?#]+|fb\.com/|instagram\.com/|twitter\.com/|x\.com/|tiktok\.com/@|snapchat\.com/add|"
                           r"youtube\.com/(?:@|user/|c/|channel/)|github\.com/[^/?#]+|/(?:~|@)[^/?#]+|/(?:profile|profiles|people|person|user|users|u|member|members|staff|team|employee|contact|about-us/team)/[^/?#]+|"
                           r"[?&](?:email|e-mail|mail|phone|tel|mobile|name|first|last|fname|lname|user|username|uid|contact)=|[0-9]{7,}", re.I)
_EMAIL_PATS = [re.compile(p, re.I) for p in (
    r"[a-z0-9._%+'-]+[ \t]*[\[({<][ \t]*(?:at|arobase|@)[ \t]*[\])}>][ \t]*[a-z0-9-]+(?:[ \t]*(?:[\[({<][ \t]*(?:dot|point|\.)[ \t]*[\])}>]|\.)[ \t]*[a-z0-9-]+)+",
    r"[a-z0-9._%+'-]+[ \t]*@[ \t]*[a-z0-9-]+(?:[ \t]*(?:[\[({<][ \t]*(?:dot|point)[ \t]*[\])}>]|[ \t]+(?:dot|point)[ \t]+)[ \t]*[a-z0-9-]+)+",
    r"[a-z0-9._%+'-]{2,}[ \t]+(?:at|arobase)[ \t]+[a-z0-9-]+(?:[ \t]+(?:dot|point)[ \t]+[a-z0-9-]+)+",
    r"[a-z0-9._%+'-]{2,}[ \t]+(?:at|arobase)[ \t]+[a-z][a-z0-9-]*(?:\.[a-z0-9-]+)*\.[a-z]{2,}",
    r"[a-z0-9._%+'-]+ ?@ ?[a-z0-9-]+(?:\.[a-z0-9-]+)+")]
_HANDLE = re.compile(r"(?<![a-z0-9._@])@[a-z0-9_.]{3,}", re.I)
_NANP = re.compile(r"(?<![0-9])\(?[0-9]{3}\)?([^a-z0-9\s])[0-9]{3}\1[0-9]{4}(?![0-9])", re.I)
_PHONE_CAND = re.compile(r"[+(]?[0-9][0-9 \t.()/–—\-]{5,}[0-9]")
_RUN7 = re.compile(r"(?<![0-9])[0-9]{7,}(?![0-9])")
_DIGIT_WORDS = re.compile(r"(?<![a-z0-9])(?:(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|un|deux|trois|quatre|cinq|sept|huit|neuf|[0-9])(?:[ \t,.\-]+|$)){7,}", re.I)
_PROTECT = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|(?<![0-9-])[0-9]{4}-[0-9]{2}-[0-9]{2}(?![0-9])(?:[t ][0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:[.,][0-9]+)?)?(?:z|[+-][0-9]{2}(?::?[0-9]{2})?)?)?", re.I)
_HEX = re.compile(r"(?:0x)?(?:[0-9a-fA-F]{2}){8,}")
_B64 = re.compile(r"[A-Za-z0-9+/_-]{16,}={0,2}")
_HASH = re.compile(r"[0-9a-f]{32,}", re.I)
_PRINTABLE = re.compile(r"^[\x20-\x7e\t\r\n -￿]{4,}$")
_EMAIL_STRICT = re.compile(r"[a-z0-9._%+'-]{2,}@[a-z0-9-]{2,}(?:\.[a-z0-9-]{2,})+", re.I)
_SPLIT = re.compile(r"[\s.,;:/\\|()<>\[\]{}\"'`~!?@#$%^&*+=_-]+")


class Known:
    """The client names / emails / phones known right now, compiled once."""
    def __init__(self, names=(), contacts=(), emails=()):
        phrases, parts, squashed, phones = set(), set(), set(), set()
        for kind, values in (("n", names), ("c", contacts), ("e", emails)):
            for v in values:
                if not v:
                    continue
                f = fold(str(v).strip()).lower()
                if len(f) < 2:
                    continue
                d = re.sub(r"[^0-9]", "", f)
                if len(d) >= 7:
                    phones.add(d[-10:])
                    if kind != "n":
                        continue
                if kind == "e" or (kind == "c" and "@" in f):
                    f = f.split("@")[0]
                tok = [x for x in _SPLIT.split(f) if x]
                if not tok or (len(tok) == 1 and len(tok[0]) < 3):
                    continue
                phrases.add("[^a-z0-9]{0,3}".join(re.escape(x) for x in tok))
                joined = re.sub(r"[^a-z0-9]", "", "".join(tok))
                if len(joined) >= 6:
                    squashed.add(joined)
                if kind != "e":
                    for w in tok:
                        if len(w) >= 3 and w not in STOP and not w.isdigit():
                            parts.add(re.escape(w))
                            if len(w) >= 5:
                                squashed.add(re.sub(r"[^a-z0-9]", "", w))
        alts = sorted(phrases | parts, key=lambda x: (-len(x), x))
        self.name_re = re.compile("(?<![a-z0-9])(?:" + "|".join(alts) + ")(?![a-z0-9])", re.I) if alts else None
        self.squashed = sorted(s for s in squashed if len(s) >= 5)
        self.phones = sorted(phones)
        self.n_terms = len(alts)


EMPTY = Known()


def _patterns(t: str, k: Known) -> str:
    for m in sorted(set(_URL.findall(t)), key=len, reverse=True):
        if _PERSONAL_URL.search(m) or (k.name_re and k.name_re.search(m)):
            t = t.replace(m, "[redacted:url]")
    for p in _EMAIL_PATS:
        t = p.sub("[redacted:email]", t)
    t = _HANDLE.sub("[redacted:handle]", t)
    t = _NANP.sub("[redacted:phone]", t)
    for m in sorted(set(_PHONE_CAND.findall(t)), key=len, reverse=True):
        d = re.sub(r"[^0-9]", "", m)
        if len(d) >= 9 or (m[:1] == "+" and len(d) >= 7) or (len(d) == 7 and re.fullmatch(r"[0-9]{3}[ .\-][0-9]{4}", m)):
            t = t.replace(m, "[redacted:phone]")
    t = _RUN7.sub("[redacted:id]", t)
    t = _DIGIT_WORDS.sub("[redacted:phone] ", t)
    if k.name_re:
        t = k.name_re.sub("[redacted:name]", t)
    return t


def _probe(t: str, k: Known, depth: int = 0) -> str:
    if depth > 2:
        return t
    for rx, kind in ((_HEX, "hex"), (_B64, "b64")):
        for m in sorted(set(rx.findall(t)), key=len, reverse=True):
            try:
                if kind == "hex":
                    raw = binascii.unhexlify(re.sub(r"^0x", "", m))
                else:
                    b = m.rstrip("=").replace("-", "+").replace("_", "/")
                    if len(b) % 4 == 1:
                        continue
                    raw = base64.b64decode(b + "=" * (-len(b) % 4), validate=True)
                dec = raw.decode("utf-8")
            except Exception:
                continue
            if not _PRINTABLE.match(dec):
                continue
            f = fold(dec)
            if _patterns(f, k) != f or _probe(f, k, depth + 1) != f:
                t = t.replace(m, "[redacted:encoded]")
    return t


def scrub(text, known: Known = EMPTY, max_len: int | None = None) -> str | None:
    """Scrubbed copy of `text` (LIGHT mode: never blanks a field for its topic). Text in which nothing is found is returned UNCHANGED. Any error returns the marker."""
    if text is None:
        return None
    try:
        t = _normalise(str(text))
        t1 = t
        prot: list[str] = []
        def hold(m):
            if len(prot) >= 6000:
                raise ValueError("too many protected tokens")
            prot.append(m.group(0))
            return chr(0xE000 + len(prot) - 1)
        t = _PROTECT.sub(hold, t)
        t = _probe(t, known)
        t = re.sub(r"[0-9a-f]{32,}", lambda m: hold(m) if re.search(r"[a-f]", m.group(0), re.I) else m.group(0), t, flags=re.I)
        r = _patterns(t, known)
        for i in range(len(prot) - 1, -1, -1):
            r = r.replace(chr(0xE000 + i), prot[i])
        sq = re.sub(r"[^a-z0-9]", "", r.lower())
        flagged = any(s in sq for s in known.squashed)
        dg = re.sub(r"[^0-9]", "", r)
        flagged = flagged or any(len(p) >= 7 and p in dg for p in known.phones)
        sq2 = re.sub(r"[ \t\r\n]", "", r)
        flagged = flagged or any(_EMAIL_STRICT.search(w) for w in re.findall(r"(.{0,80}@.{0,160})", sq2, re.S)) or ("@" in r and bool(_EMAIL_STRICT.search(r[::-1])))
        flagged = flagged or any(_EMAIL_PATS[0].search(w) for w in re.findall(r"(.{0,80}[\[({<](?:at|arobase|@)[\])}>].{0,160})", sq2, re.S | re.I))
        if flagged:
            return UNCERTAIN       # a known name / phone / email survives only in spaced, split or reversed form: do not vouch for the field
        return str(text) if r == t1 else r
    except Exception:
        logger.warning("HQ scrub failed; storing the marker instead of the raw text")
        return UNCERTAIN


# ------------------------------------------------------------------ known clients (engine side)
_LOCK = threading.Lock()
_CACHE = {"at": 0.0, "known": EMPTY, "ok": False}
TTL = 300
SOURCES = (("leads", "name", "n"), ("leads", "phone", "c"), ("leads", "email", "e"), ("setters", "name", "n"), ("setters", "contact", "c"), ("ws_leads", "name", "n"), ("ws_leads", "phone", "c"),
           ("ws_leads", "email", "e"), ("client_workspaces", "name", "n"), ("setter_events", "client", "n"))


def load_known(get) -> Known:
    """Fetch the known client names through `get(path) -> list` (the engine's PostgREST reader). Any failure keeps the previous list (or an empty one) and the patterns still apply."""
    names, contacts, emails, ok = [], [], [], True
    by_table: dict = {}
    for table, col, kind in SOURCES:
        by_table.setdefault(table, []).append((col, kind))
    for table, cols in by_table.items():
        try:
            off = 0
            while off < 10000:
                rows = get(f"{table}?select={','.join(c for c, _ in cols)}&order={cols[0][0]}.asc&limit=1000&offset={off}") or []
                if not isinstance(rows, list):
                    break
                for r in rows:
                    for col, kind in cols:
                        (names if kind == "n" else contacts if kind == "c" else emails).append((r or {}).get(col))
                if len(rows) < 1000:
                    break
                off += 1000
        except Exception:
            ok = False
    return Known(names, contacts, emails), ok


def known(get) -> Known:
    with _LOCK:
        if time.time() - _CACHE["at"] < TTL and _CACHE["known"] is not EMPTY:
            return _CACHE["known"]
    k, ok = load_known(get)
    with _LOCK:
        if ok or _CACHE["known"] is EMPTY:
            _CACHE.update(at=time.time(), known=k, ok=ok)
        else:
            _CACHE["at"] = time.time() - TTL + 30      # retry soon, keep serving the previous list
        return _CACHE["known"] if not ok and _CACHE["known"] is not EMPTY else k


def reset_cache() -> None:
    with _LOCK:
        _CACHE.update(at=0.0, known=EMPTY, ok=False)


def scrub_stored(text, get) -> str | None:
    """What the engine calls: scrub with the current known-client list."""
    try:
        k = known(get)
    except Exception:
        k = EMPTY
    return scrub(text, k)
