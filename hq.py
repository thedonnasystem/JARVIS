"""
Fendezy HQ bridge for Jarvis.

Jarvis is the only agent allowed to contact the owner. Other agents write to the
HQ database; this module delivers the owner-bound messages that Jarvis is cleared
to send, and lets Jarvis run any HQ agent through the spend gateway.

Everything here is inert unless BOTH of these are set (see .env.example):
    HQ_SUPABASE_URL           e.g. https://<project>.supabase.co
    HQ_SUPABASE_SERVICE_KEY   the HQ project's service key (keep it in Railway Variables)
Messages only ever go to JARVIS_OWNER_ID.
"""

import contextvars
import json
import logging
import os
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from decimal import Decimal

logger = logging.getLogger(__name__)

HQ_SUPABASE_URL = (os.environ.get("HQ_SUPABASE_URL") or "").rstrip("/")
HQ_SUPABASE_SERVICE_KEY = os.environ.get("HQ_SUPABASE_SERVICE_KEY") or ""
JARVIS_OWNER_ID = os.environ.get("JARVIS_OWNER_ID") or ""

KIND_LABEL = {
    "brief": "Daily brief",
    "money": "Money",
    "health": "Company health",
    "contract": "Contract needs your signature",
    "proposal": "Improvement proposal",
    "emergency": "EMERGENCY",
}


def hq_enabled() -> bool:
    return bool(HQ_SUPABASE_URL and HQ_SUPABASE_SERVICE_KEY and JARVIS_OWNER_ID)


# The backup uses its own, narrower identity (the `backup_reader` database role) for its RPC calls: hq_backup sets this for the duration of a call; every other request keeps the service key.
AUTH_OVERRIDE: contextvars.ContextVar = contextvars.ContextVar("hq_auth_override", default=None)
# What goes in the `apikey` header while AUTH_OVERRIDE is set. A Supabase gateway checks `apikey` against the PROJECT's API keys before PostgREST sees the request, so a custom-role JWT there is
# expected to be rejected (401): the gateway key is the project's anon / publishable key (public by design, it carries no data access here: the JWT in Authorization decides the database role).
# None = send the override token as apikey too (a plain PostgREST without a gateway). The service key is NEVER used for an overridden call.
APIKEY_OVERRIDE: contextvars.ContextVar = contextvars.ContextVar("hq_apikey_override", default=None)


def auth_headers() -> tuple[str, str]:
    """(apikey, bearer token) for the current call. Without an override both are the service key; with one, the bearer is the override token and apikey is the gateway key or that same token."""
    override = AUTH_OVERRIDE.get()
    if not override:
        return HQ_SUPABASE_SERVICE_KEY, HQ_SUPABASE_SERVICE_KEY
    return (APIKEY_OVERRIDE.get() or override), override


# ---- scoped identities (FENDEZY GROUP Phase 1, M1; migrations/20261127_org_access_v1.sql) ---------------------------------------------------------------------
# A call can run as a NARROW identity (Jarvis group scope, an office manager, the auditor) instead of the service key: `with hq.as_identity("jarvis"): ...` or
# `_request(..., identity="jarvis")`. The tokens are minted by the owner (ops/mint_scoped_tokens.html) and installed as ONE variable:
#   FZ_SCOPED_TOKENS   JSON object {"<identity>": "<jwt>", ...}; each JWT has role fz_jarvis / fz_office_agent / fz_auditor and the claim identity=<identity>
#   FZ_GATEWAY_APIKEY  the project's anon / publishable key for the `apikey` header (Supabase's gateway checks it; the scoped JWT goes in Authorization)
# FZ_SCOPED_TOKENS unset or empty (nothing installed): the call keeps the service key, exactly as before (additive; nothing breaks before install).
# FZ_SCOPED_TOKENS set (even unreadable): the call uses this identity's token or FAILS (ScopedTokenError) when the token is missing, malformed, expired, for another role or
# identity; it never silently widens to the service key once tokens are installed, and a call the database refuses is never retried with the service key.
SCOPED_TOKENS_ENV = "FZ_SCOPED_TOKENS"
SCOPED_GATEWAY_ENV = "FZ_GATEWAY_APIKEY"
SCOPED_ROLES = ("fz_jarvis", "fz_office_agent", "fz_auditor")
_scoped_cache: dict = {"raw": None, "tokens": {}}
_scoped_warned: set = set()


class ScopedTokenError(RuntimeError):
    """as_identity(..., require=True) found no usable token: the caller asked never to fall back to the service key."""


def _jwt_claims(token: str) -> dict | None:
    """Claims of a JWT WITHOUT verifying it (the database verifies the signature). None when it is not a decodable JWT."""
    import base64
    try:
        parts = (token or "").strip().split(".")
        if len(parts) != 3 or not all(parts):
            return None
        c = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
        return c if isinstance(c, dict) else None
    except Exception:
        return None


def _scoped_tokens() -> dict | None:
    """None = nothing installed (unset, empty or an empty JSON object). A value that is set but not a JSON object of strings is 'installed but broken': {"": ""}
    (no identity can match it, so every scoped call refuses instead of widening)."""
    raw = os.environ.get(SCOPED_TOKENS_ENV, "")
    if raw != _scoped_cache["raw"]:
        tokens = None
        if raw.strip():
            try:
                parsed = json.loads(raw)
            except ValueError:
                parsed = None
            if isinstance(parsed, dict) and all(isinstance(v, str) for v in parsed.values()):
                tokens = {str(k): v.strip() for k, v in parsed.items()} or None
            else:
                logger.warning("HQ: %s is set but is not a JSON object of tokens; scoped calls will refuse (no service key fallback)", SCOPED_TOKENS_ENV)
                tokens = {"": ""}
        _scoped_cache.update(raw=raw, tokens=tokens)
    return _scoped_cache["tokens"]


def scoped_token_state(identity: str, now: float | None = None) -> tuple[str, str | None]:
    """(state, token). state: off (nothing installed) | ok | missing | malformed | wrongrole | wrongidentity | hassub | servicekey | expired. Only 'ok' returns the token."""
    import math
    import time
    tokens = _scoped_tokens()
    if tokens is None:
        return "off", None
    tok = tokens.get(identity, "")
    if not tok:
        return "missing", None
    if HQ_SUPABASE_SERVICE_KEY and tok == HQ_SUPABASE_SERVICE_KEY:
        return "servicekey", None
    c = _jwt_claims(tok)
    if c is None:
        return "malformed", None
    if c.get("role") not in SCOPED_ROLES:
        return "wrongrole", None       # never service_role, backup_reader, anon or authenticated through this path
    if c.get("identity") != identity:
        return "wrongidentity", None
    if "sub" in c:
        return "hassub", None          # the database refuses it too: a sub could pass for a signed-in app user
    exp = c.get("exp")
    now = time.time() if now is None else now
    if isinstance(exp, bool) or not isinstance(exp, (int, float)) or not math.isfinite(exp) or exp <= now + 30:
        return "expired", None
    return "ok", tok


def scoped_gateway_key() -> str | None:
    """The `apikey` header for scoped calls, or None (send the scoped JWT there: a plain PostgREST). Refuses anything that is, or looks like, a privileged key."""
    k = os.environ.get(SCOPED_GATEWAY_ENV, "").strip()
    if not k:
        return None
    role = (_jwt_claims(k) or {}).get("role")
    if (HQ_SUPABASE_SERVICE_KEY and k == HQ_SUPABASE_SERVICE_KEY) or k.startswith("sb_secret_") or role not in (None, "anon"):
        raise ScopedTokenError(f"{SCOPED_GATEWAY_ENV} must be the project's anon / publishable key: a service or secret key is refused")
    return k


class as_identity:
    """Context manager: requests inside it run as `identity`. Nothing installed: they keep the service key (or raise with require=True). Tokens installed: this identity's
    token is used, and a missing / invalid one raises ScopedTokenError (never a silent fallback). `.scoped` says which happened. An override already in force (the
    backup identity) is never replaced."""

    def __init__(self, identity: str, require: bool = False):
        self.identity, self.require, self.scoped, self._resets = identity, require, False, None

    def __enter__(self):
        if AUTH_OVERRIDE.get():
            if self.require:
                raise ScopedTokenError("another identity is already in force for this call")
            return self
        state, tok = scoped_token_state(self.identity)
        if state == "off" and not self.require:
            return self                                                    # nothing installed yet: today's behaviour
        if state != "ok":
            if (self.identity, state) not in _scoped_warned:
                _scoped_warned.add((self.identity, state))
                logger.warning("HQ: scoped token for %s refused (%s); the call is not sent", self.identity, state)
            raise ScopedTokenError(f"no usable scoped token for {self.identity} ({state})")
        gw = scoped_gateway_key()
        self._resets = (AUTH_OVERRIDE.set(tok), APIKEY_OVERRIDE.set(gw))
        self.scoped = True
        return self

    def __exit__(self, *exc):
        if self._resets:
            APIKEY_OVERRIDE.reset(self._resets[1])
            AUTH_OVERRIDE.reset(self._resets[0])
            self._resets = None
        return False


def scoped_check(identity: str = "jarvis") -> dict:
    """Install check for the owner's tokens: asks the database who this token is (fz_whoami). Never falls back to the service key."""
    state, _ = scoped_token_state(identity)
    if state != "ok":
        return {"ok": False, "identity": identity, "reason": f"token {state}"}
    try:
        with as_identity(identity, require=True):
            r = _request("POST", "/rest/v1/rpc/fz_whoami", {})
    except urllib.error.HTTPError as e:
        return {"ok": False, "identity": identity, "reason": f"HTTP {e.code} (gateway key or token refused)"}
    except (urllib.error.URLError, TimeoutError, ScopedTokenError) as e:
        return {"ok": False, "identity": identity, "reason": str(e)[:200]}
    return r if isinstance(r, dict) else {"ok": False, "identity": identity, "reason": "unreadable reply"}


def _request(method: str, path: str, body: dict | None = None, timeout: int = 30, prefer: str | None = None, exact: bool = False, identity: str | None = None):
    if identity:
        with as_identity(identity):
            return _request(method, path, body, timeout, prefer, exact)
    url = f"{HQ_SUPABASE_URL}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    apikey, token = auth_headers()
    req.add_header("apikey", apikey)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    if prefer:
        req.add_header("Prefer", prefer)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        if not raw:
            return None
        # exact=True keeps decimal numbers as Decimal (scale and precision intact); used by the backup so money columns are not rounded through float
        return json.loads(raw, parse_float=Decimal) if exact else json.loads(raw)


def format_owner_message(msg: dict) -> str:
    label = KIND_LABEL.get(msg.get("kind", ""), "Message")
    prefix = "\U0001F6A8 " if msg.get("kind") == "emergency" else ""
    note = ""
    if msg.get("channel") in ("text", "call"):
        note = f"\n\n(Sent by Telegram: the {msg['channel']} channel is not connected yet.)"
    return f"{prefix}{label}\n\n{msg.get('body', '')}{note}"


QUIET_START, QUIET_END = 22, 7  # Toronto hours; non-emergency messages wait until morning


def in_quiet_hours(now: datetime | None = None) -> bool:
    from zoneinfo import ZoneInfo
    h = (now or datetime.now(ZoneInfo("America/Toronto"))).hour
    return h >= QUIET_START or h < QUIET_END


def decision_buttons(msg_id: str):
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup
    return InlineKeyboardMarkup([[
        InlineKeyboardButton("Approve", callback_data=f"hqd:ok:{msg_id}"),
        InlineKeyboardButton("Reject", callback_data=f"hqd:no:{msg_id}"),
    ]])


def option_buttons(msg_id: str, options: list):
    """Task Brief: one button per option (max 4), each on its own row so long labels stay readable."""
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup
    return InlineKeyboardMarkup([[InlineKeyboardButton(str(o)[:60], callback_data=f"hqq:{i}:{msg_id}")]
                                 for i, o in enumerate(options[:4])])


async def deliver_owner_messages(context) -> None:
    """Repeating job: send unsent owner messages to the owner on Telegram, oldest first."""
    if not hq_enabled():
        return
    try:
        rows = _request(
            "GET",
            "/rest/v1/owner_messages?sent_at=is.null"
            f"&or=(deliver_after.is.null,deliver_after.lte.{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')})"
            "&order=created_at.asc&limit=10"
            "&select=id,kind,channel,body,needs_decision,options",
        ) or []
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        logger.warning("HQ: could not read owner_messages: %s", e)
        return
    quiet = in_quiet_hours()
    for msg in rows:
        if quiet and msg.get("kind") != "emergency":
            continue  # held until 7am Toronto; only emergencies wake the owner
        try:
            # Plain text on purpose: no parse_mode, so message content cannot inject formatting.
            if msg.get("options"):
                markup = option_buttons(msg["id"], msg["options"])
            else:
                markup = decision_buttons(msg["id"]) if msg.get("needs_decision") else None
            import hq_core
            text = hq_core.address(format_owner_message(msg))      # every owner message, whichever module or SQL function queued it, says "sir"
            # --- hqui begin: the morning/evening brief carries the inbox count (read-only; '' if unreadable) ---
            if msg.get("kind") == "brief":
                try:
                    import hq_inbox
                    text = hq_inbox.append_to_brief(text)
                except Exception:  # never let the count block the brief
                    logger.exception("HQ: inbox line skipped")
            # --- hqui end ---
            await context.bot.send_message(int(JARVIS_OWNER_ID), text, reply_markup=markup)
            try:
                import hq_push
                await hq_push.notify(msg)
            except Exception:  # push is a bonus channel; Telegram already delivered
                pass
        except Exception as e:  # leave unsent so it is retried next minute
            logger.warning("HQ: Telegram send failed for %s: %s", msg.get("id"), e)
            return
        try:
            _request(
                "PATCH",
                f"/rest/v1/owner_messages?id=eq.{urllib.parse.quote(str(msg['id']))}",
                {"sent_at": datetime.now(timezone.utc).isoformat()},
                prefer="return=minimal",
            )
        except (urllib.error.URLError, TimeoutError) as e:
            logger.error("HQ: sent %s but could not mark it sent: %s", msg.get("id"), e)
            return


def run_agent(agent: str, task: str, max_output_tokens: int = 1000) -> dict:
    """Run one HQ agent turn through the spend gateway. Returns the function's JSON."""
    if not (HQ_SUPABASE_URL and HQ_SUPABASE_SERVICE_KEY):
        return {"error": "HQ is not configured"}
    try:
        return _request(
            "POST",
            "/functions/v1/hq-run",
            {"agent": agent, "task": task, "max_output_tokens": max_output_tokens},
            timeout=100,
        ) or {}
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"error": f"HQ returned HTTP {e.code}"}
    except (urllib.error.URLError, TimeoutError) as e:
        return {"error": f"HQ unreachable: {e}"}
