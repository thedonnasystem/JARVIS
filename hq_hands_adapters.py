"""Jarvis hands: the connector adapters (one small class per service, official APIs only).

Every adapter DECLARES: auth type (oauth2 / api_key / none), allowed actions, rate limit, cost per action, sign-up mode (assisted / none: there is no
automated sign-up; the Chairman always creates accounts himself on the official page), where AI disclosure goes, and its terms constraint. The database row in public.hand_connectors
(migration 20261124_jarvis_hands_v1) must match these declarations; test_hq_hands checks it. Adapters are code, so a new one is locked code: it goes through the
self-edit pipeline and needs the owner's approval (ops/PROTECTED_PATHS.json); there is no way to add a service adapter from the database.

Adapters never see the model: the executor (hq_hands.run_action) hands them a Ctx with the approved action, the account record (vault REFERENCES only) and
callables to read the token from the vault and make HTTPS calls. Tokens are never logged and never returned.
"""
from __future__ import annotations

import base64
import hashlib
import json
import re
import secrets
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import date, timedelta

ACTIONS = ("create_account", "post", "upload", "send", "update", "deploy")
PUBLIC_ACTIONS = frozenset({"post", "upload", "update", "deploy"})
AI_CAPTION = "Made with AI."
MAX_MEDIA_BYTES = 256 * 1024 * 1024
GRAPH = "https://graph.facebook.com/v21.0"


class HandError(Exception):
    """The action failed; the message is safe to show (never contains a secret)."""


class Secret:
    """A token in memory. Its repr / str never show the value; .reveal() is used only at the moment it is typed or sent."""
    __slots__ = ("_v",)

    def __init__(self, value: str):
        self._v = str(value)

    def reveal(self) -> str:
        return self._v

    def __repr__(self):
        return "Secret(***)"

    __str__ = __repr__

    def __eq__(self, other):
        return isinstance(other, Secret) and secrets.compare_digest(self._v, other._v)

    __hash__ = None


# ------------------------------------------------------------------------------------------------------------------- HTTP
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A 3xx is returned to the adapter, never followed: urllib would re-send the Authorization header to whatever origin the redirect names."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_NO_REDIRECT = urllib.request.build_opener(_NoRedirect)


def http(method: str, url: str, headers: dict | None = None, json_body=None, form: dict | None = None, data: bytes | None = None, timeout: int = 60):
    """-> (status, parsed JSON or raw bytes, response headers). HTTPS only. Errors come back as (status, body) without raising, so adapters decide."""
    if not url.startswith("https://"):
        raise HandError("refused: only https endpoints")
    h = dict(headers or {})
    if json_body is not None:
        data, h["Content-Type"] = json.dumps(json_body).encode(), "application/json"
    elif form is not None:
        data, h["Content-Type"] = urllib.parse.urlencode(form).encode(), "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with _NO_REDIRECT.open(req, timeout=timeout) as r:
            raw, status, hdrs = r.read(), r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        raw, status, hdrs = e.read() or b"", e.code, dict(e.headers or {})
    except (urllib.error.URLError, OSError) as e:
        raise HandError(f"network error: {type(e).__name__}") from None
    try:
        return status, json.loads(raw.decode() or "null"), hdrs
    except (ValueError, UnicodeDecodeError):
        return status, raw, hdrs


def _err(service: str, status, body) -> HandError:
    """A safe error line: status and the provider's error code/message, cut short; never echoes request data."""
    msg = ""
    if isinstance(body, dict):
        e = body.get("error")
        msg = (e.get("message") or e.get("code") or "") if isinstance(e, dict) else str(e or body.get("message") or body.get("detail") or "")
    return HandError(f"{service} refused (HTTP {status}) {str(msg)[:120]}".strip())


@dataclass
class Ctx:
    """What an adapter gets. token() reads the vault entry of the connected account (a dict); never log it."""
    action: dict
    account: dict | None
    connector: dict
    token: callable = None
    save_token: callable = None          # (token dict) -> stores a refreshed token in the vault and records the new reference
    http: callable = http
    rpc: callable = None

    @property
    def payload(self) -> dict:
        return self.action.get("payload") or {}

    def text(self) -> str:
        t = str(self.payload.get("text") or "").strip()
        if self.action.get("ai_generated") and self.connector.get("ai_label") == "caption" and AI_CAPTION.lower() not in t.lower():
            t = (t + "\n\n" + AI_CAPTION).strip()
        return t

    def media(self) -> list[str]:
        m = self.payload.get("media") or []
        m = [m] if isinstance(m, str) else list(m)
        for u in m:
            if not re.match(r"^https://[^\s]{4,}$", str(u)):
                raise HandError("refused: media must be https URLs")
        return [str(u) for u in m]


class Adapter:
    slug = ""
    title = ""
    auth = "none"                 # oauth2 | api_key | none
    actions: tuple = ()
    signup = "assisted"           # assisted | none (the Chairman always signs up himself)
    max_actions_per_day = 0
    cost_cents_per_action = 0
    ai_label = "none"             # api_field | caption | none
    terms = ""

    def execute(self, ctx: Ctx) -> str:
        """Do the approved action; return the platform's id for it (post id, video id, deploy id...)."""
        raise HandError(f"{self.slug} cannot {ctx.action.get('action')}")

    # OAuth2 adapters
    def authorize_url(self, state: str, verifier: str, env: dict) -> str:
        raise HandError(f"{self.slug} has no OAuth connection")

    def exchange(self, code: str, verifier: str, env: dict, call=http) -> list[dict]:
        """-> [{handle, external_id, token: dict, expires_at, scopes}] (one per page / channel / profile)."""
        raise HandError(f"{self.slug} has no OAuth connection")


def _redirect(env) -> str:
    r = env.get("HANDS_OAUTH_REDIRECT") or ""
    if not r.startswith("https://"):
        raise HandError("HANDS_OAUTH_REDIRECT (an https URL registered in the developer app) is not set")
    return r


def _need(env, *names):
    miss = [n for n in names if not env.get(n)]
    if miss:
        raise HandError("not configured: " + ", ".join(miss))
    return [env[n] for n in names]


def _slug_handle(name: str) -> str:
    return (re.sub(r"[^A-Za-z0-9._-]+", "_", name or "").strip("_") or "account")[:60]


# ------------------------------------------------------------------------------------------------------------------- Meta
META_SCOPES = "pages_show_list,pages_manage_posts,pages_read_engagement,instagram_basic,instagram_content_publish,business_management"


class _Meta(Adapter):
    auth = "oauth2"
    ai_label = "caption"

    def authorize_url(self, state, verifier, env):
        app_id, = _need(env, "META_APP_ID")
        return "https://www.facebook.com/v21.0/dialog/oauth?" + urllib.parse.urlencode(
            {"client_id": app_id, "redirect_uri": _redirect(env), "state": state, "scope": META_SCOPES, "response_type": "code"})

    def exchange(self, code, verifier, env, call=http):
        app_id, secret = _need(env, "META_APP_ID", "META_APP_SECRET")
        s, b, _ = call("GET", f"{GRAPH}/oauth/access_token?" + urllib.parse.urlencode({"client_id": app_id, "client_secret": secret, "redirect_uri": _redirect(env), "code": code}))
        if s != 200 or not isinstance(b, dict) or "access_token" not in b:
            raise _err("Meta", s, b)
        s, b, _ = call("GET", f"{GRAPH}/oauth/access_token?" + urllib.parse.urlencode(
            {"grant_type": "fb_exchange_token", "client_id": app_id, "client_secret": secret, "fb_exchange_token": b["access_token"]}))
        if s != 200 or not isinstance(b, dict) or "access_token" not in b:
            raise _err("Meta", s, b)
        s, pages, _ = call("GET", f"{GRAPH}/me/accounts?" + urllib.parse.urlencode(
            {"fields": "id,name,access_token,instagram_business_account{id,username}", "access_token": b["access_token"]}))
        if s != 200 or not isinstance(pages, dict):
            raise _err("Meta", s, pages)
        out = []
        for p in pages.get("data") or []:
            if self.slug == "meta-facebook":
                out.append({"handle": _slug_handle(p.get("name")), "external_id": str(p["id"]), "token": {"access_token": p["access_token"]}, "expires_at": None, "scopes": META_SCOPES.split(",")})
            elif self.slug == "meta-instagram" and p.get("instagram_business_account"):
                ig = p["instagram_business_account"]
                out.append({"handle": _slug_handle(ig.get("username")), "external_id": str(ig["id"]), "token": {"access_token": p["access_token"]}, "expires_at": None, "scopes": META_SCOPES.split(",")})
        if not out:
            raise HandError("Meta returned no Page" + (" with a linked Instagram professional account" if self.slug == "meta-instagram" else ""))
        return out


class MetaFacebook(_Meta):
    slug, title = "meta-facebook", "Facebook Page (Meta Graph API)"
    actions, max_actions_per_day = ("create_account", "post"), 5
    terms = "The Chairman creates the Page himself; publishing only through the Graph API with a Page token"

    def execute(self, ctx):
        page, tok = ctx.account["external_id"], ctx.token()["access_token"]
        media = ctx.media()
        if media:
            s, b, _ = ctx.http("POST", f"{GRAPH}/{page}/photos", form={"url": media[0], "caption": ctx.text(), "access_token": tok})
        else:
            s, b, _ = ctx.http("POST", f"{GRAPH}/{page}/feed", form={"message": ctx.text(), "access_token": tok})
        if s != 200 or not isinstance(b, dict) or not (b.get("post_id") or b.get("id")):
            raise _err("Facebook", s, b)
        return str(b.get("post_id") or b["id"])


class MetaInstagram(_Meta):
    slug, title = "meta-instagram", "Instagram professional account (Instagram Graph API)"
    actions, max_actions_per_day = ("create_account", "post"), 5
    terms = "The Chairman signs up himself; content publishing API only, Meta caps API posts per 24 h"
    poll_tries, poll_wait = 20, 6.0

    def execute(self, ctx):
        ig, tok = ctx.account["external_id"], ctx.token()["access_token"]
        media = ctx.media()
        if not media:
            raise HandError("refused: an Instagram post needs an image or video URL")
        is_video = bool(re.search(r"\.(mp4|mov)(\?|$)", media[0], re.I))
        body = {"caption": ctx.text(), "access_token": tok}
        body.update({"media_type": "REELS", "video_url": media[0]} if is_video else {"image_url": media[0]})
        s, b, _ = ctx.http("POST", f"{GRAPH}/{ig}/media", form=body)
        if s != 200 or not isinstance(b, dict) or "id" not in b:
            raise _err("Instagram", s, b)
        container = b["id"]
        if is_video:
            import time
            for _ in range(self.poll_tries):
                s, st, _ = ctx.http("GET", f"{GRAPH}/{container}?fields=status_code&access_token={urllib.parse.quote(tok)}")
                code = (st or {}).get("status_code") if isinstance(st, dict) else None
                if code == "FINISHED":
                    break
                if code in ("ERROR", "EXPIRED"):
                    raise HandError(f"Instagram could not process the video ({code})")
                time.sleep(self.poll_wait)
            else:
                raise HandError("Instagram video still processing; retried later")
        s, b, _ = ctx.http("POST", f"{GRAPH}/{ig}/media_publish", form={"creation_id": container, "access_token": tok})
        if s != 200 or not isinstance(b, dict) or "id" not in b:
            raise _err("Instagram", s, b)
        return str(b["id"])


# ------------------------------------------------------------------------------------------------------------------- TikTok
class TikTok(Adapter):
    slug, title, auth = "tiktok", "TikTok (Content Posting API)", "oauth2"
    actions, max_actions_per_day, ai_label = ("create_account", "post", "upload"), 3, "api_field"
    terms = "The Chairman signs up himself; unaudited API clients may only post privately"
    API = "https://open.tiktokapis.com/v2"

    def authorize_url(self, state, verifier, env):
        key, = _need(env, "TIKTOK_CLIENT_KEY")
        return "https://www.tiktok.com/v2/auth/authorize/?" + urllib.parse.urlencode(
            {"client_key": key, "scope": "user.info.basic,video.publish", "response_type": "code", "redirect_uri": _redirect(env), "state": state})

    def _token(self, form, env, call):
        key, secret = _need(env, "TIKTOK_CLIENT_KEY", "TIKTOK_CLIENT_SECRET")
        s, b, _ = call("POST", f"{self.API}/oauth/token/", form={"client_key": key, "client_secret": secret, **form})
        if s != 200 or not isinstance(b, dict) or "access_token" not in b:
            raise _err("TikTok", s, b)
        return b

    def exchange(self, code, verifier, env, call=http):
        b = self._token({"code": code, "grant_type": "authorization_code", "redirect_uri": _redirect(env)}, env, call)
        tok = {"access_token": b["access_token"], "refresh_token": b.get("refresh_token"), "expires_in": b.get("expires_in")}
        return [{"handle": "tiktok_" + str(b.get("open_id", ""))[:20], "external_id": str(b.get("open_id") or "me")[:120], "token": tok, "expires_at": None,
                 "scopes": str(b.get("scope") or "").split(",")}]

    def execute(self, ctx):
        tok = ctx.token()
        media = ctx.media()
        if not media:
            raise HandError("refused: a TikTok post needs a video URL (on a domain verified in the TikTok developer app)")
        auth = {"Authorization": "Bearer " + tok["access_token"]}
        s, info, _ = ctx.http("POST", f"{self.API}/post/publish/creator_info/query/", headers=auth, json_body={})
        if s != 200 or not isinstance(info, dict):
            raise _err("TikTok", s, info)
        options = ((info.get("data") or {}).get("privacy_level_options")) or []
        level = "PUBLIC_TO_EVERYONE" if (ctx.payload.get("public") and "PUBLIC_TO_EVERYONE" in options) else "SELF_ONLY"
        body = {"post_info": {"title": ctx.text()[:2200], "privacy_level": level, "disable_comment": False, "disable_duet": False, "disable_stitch": False,
                              "is_aigc": bool(ctx.action.get("ai_generated"))},
                "source_info": {"source": "PULL_FROM_URL", "video_url": media[0]}}
        s, b, _ = ctx.http("POST", f"{self.API}/post/publish/video/init/", headers=auth, json_body=body)
        pid = ((b or {}).get("data") or {}).get("publish_id") if isinstance(b, dict) else None
        if s != 200 or not pid:
            raise _err("TikTok", s, b)
        return str(pid)


# ------------------------------------------------------------------------------------------------------------------- YouTube
class YouTube(Adapter):
    slug, title, auth = "youtube", "YouTube (Data API v3 uploads)", "oauth2"
    actions, max_actions_per_day, ai_label = ("create_account", "upload"), 3, "api_field"
    terms = "The Chairman creates the Google account / channel himself; uploads from unverified API projects stay private until Google audit"
    SCOPE = "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly"

    def access_token(self, ctx) -> str:
        tok = ctx.token()
        cid, secret = _need(ctx.connector.get("_env") or {}, "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET")
        s, b, _ = ctx.http("POST", "https://oauth2.googleapis.com/token",
                           form={"client_id": cid, "client_secret": secret, "refresh_token": tok["refresh_token"], "grant_type": "refresh_token"})
        if s != 200 or not isinstance(b, dict) or "access_token" not in b:
            raise _err("Google", s, b)
        return b["access_token"]

    def execute(self, ctx):
        media = ctx.media()
        if not media:
            raise HandError("refused: an upload needs a video URL")
        s, raw, _ = ctx.http("GET", media[0], timeout=300)
        if s != 200 or not isinstance(raw, (bytes, bytearray)) or not raw or len(raw) > MAX_MEDIA_BYTES:
            raise HandError(f"could not fetch the video (HTTP {s})")
        at = self.access_token(ctx)
        meta = {"snippet": {"title": str(ctx.payload.get("title") or ctx.text()[:100] or "Video")[:100], "description": ctx.text()[:4900], "categoryId": "22"},
                "status": {"privacyStatus": ctx.payload.get("privacy") if ctx.payload.get("privacy") in ("private", "unlisted", "public") else "private",
                           "selfDeclaredMadeForKids": False, "containsSyntheticMedia": bool(ctx.action.get("ai_generated"))}}
        s, b, h = ctx.http("POST", "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status",
                           headers={"Authorization": "Bearer " + at, "X-Upload-Content-Type": "video/*", "X-Upload-Content-Length": str(len(raw))}, json_body=meta)
        loc = {k.lower(): v for k, v in (h or {}).items()}.get("location")
        if s != 200 or not loc or not loc.startswith("https://"):
            raise _err("YouTube", s, b)
        s, b, _ = ctx.http("PUT", loc, headers={"Authorization": "Bearer " + at, "Content-Type": "video/*"}, data=bytes(raw), timeout=900)
        if s not in (200, 201) or not isinstance(b, dict) or "id" not in b:
            raise _err("YouTube", s, b)
        return str(b["id"])


# ------------------------------------------------------------------------------------------------------------------- X
class XTwitter(Adapter):
    slug, title, auth = "x-twitter", "X (API v2 posts)", "oauth2"
    actions, max_actions_per_day, ai_label = ("create_account", "post"), 5, "caption"
    terms = "The Chairman signs up himself; posting through the API only, within the app tier limits"

    def authorize_url(self, state, verifier, env):
        cid, = _need(env, "X_CLIENT_ID")
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
        return "https://x.com/i/oauth2/authorize?" + urllib.parse.urlencode(
            {"response_type": "code", "client_id": cid, "redirect_uri": _redirect(env), "scope": "tweet.read tweet.write users.read offline.access",
             "state": state, "code_challenge": challenge, "code_challenge_method": "S256"})

    def _basic(self, env):
        cid, secret = _need(env, "X_CLIENT_ID", "X_CLIENT_SECRET")
        return {"Authorization": "Basic " + base64.b64encode(f"{cid}:{secret}".encode()).decode()}

    def exchange(self, code, verifier, env, call=http):
        cid, = _need(env, "X_CLIENT_ID")
        s, b, _ = call("POST", "https://api.x.com/2/oauth2/token", headers=self._basic(env),
                       form={"grant_type": "authorization_code", "code": code, "redirect_uri": _redirect(env), "code_verifier": verifier, "client_id": cid})
        if s != 200 or not isinstance(b, dict) or "access_token" not in b:
            raise _err("X", s, b)
        s, me, _ = call("GET", "https://api.x.com/2/users/me", headers={"Authorization": "Bearer " + b["access_token"]})
        d = (me or {}).get("data") or {} if isinstance(me, dict) else {}
        return [{"handle": _slug_handle(d.get("username")), "external_id": str(d.get("id") or "me"), "token": {k: b.get(k) for k in ("access_token", "refresh_token")},
                 "expires_at": None, "scopes": str(b.get("scope") or "").split()}]

    def execute(self, ctx):
        if ctx.media():
            raise HandError("refused: X media upload is not in v1 (text posts only)")
        tok = ctx.token()
        env = ctx.connector.get("_env") or {}
        if tok.get("refresh_token") and env.get("X_CLIENT_ID"):
            s, b, _ = ctx.http("POST", "https://api.x.com/2/oauth2/token", headers=self._basic(env),
                               form={"grant_type": "refresh_token", "refresh_token": tok["refresh_token"], "client_id": env["X_CLIENT_ID"]})
            if s == 200 and isinstance(b, dict) and b.get("access_token"):
                tok = {"access_token": b["access_token"], "refresh_token": b.get("refresh_token") or tok["refresh_token"]}
                if ctx.save_token:
                    ctx.save_token(tok)
        s, b, _ = ctx.http("POST", "https://api.x.com/2/tweets", headers={"Authorization": "Bearer " + tok["access_token"]}, json_body={"text": ctx.text()[:280]})
        if s not in (200, 201) or not isinstance(b, dict) or not (b.get("data") or {}).get("id"):
            raise _err("X", s, b)
        return str(b["data"]["id"])


# ------------------------------------------------------------------------------------------------------------------- LinkedIn
def linkedin_version(today: date | None = None) -> str:
    """LinkedIn-Version header (YYYYMM). LinkedIn retires versions after about a year, so default to two months back; HANDS_LINKEDIN_VERSION overrides."""
    d = (today or date.today()).replace(day=1) - timedelta(days=40)
    return f"{d.year}{d.month:02d}"


class LinkedIn(Adapter):
    slug, title, auth = "linkedin", "LinkedIn (Posts API)", "oauth2"
    actions, max_actions_per_day, ai_label = ("create_account", "post"), 3, "caption"
    terms = "The Chairman signs up himself; member posting via the Share on LinkedIn product only"

    def authorize_url(self, state, verifier, env):
        cid, = _need(env, "LINKEDIN_CLIENT_ID")
        return "https://www.linkedin.com/oauth/v2/authorization?" + urllib.parse.urlencode(
            {"response_type": "code", "client_id": cid, "redirect_uri": _redirect(env), "state": state, "scope": "openid profile w_member_social"})

    def exchange(self, code, verifier, env, call=http):
        cid, secret = _need(env, "LINKEDIN_CLIENT_ID", "LINKEDIN_CLIENT_SECRET")
        s, b, _ = call("POST", "https://www.linkedin.com/oauth/v2/accessToken",
                       form={"grant_type": "authorization_code", "code": code, "redirect_uri": _redirect(env), "client_id": cid, "client_secret": secret})
        if s != 200 or not isinstance(b, dict) or "access_token" not in b:
            raise _err("LinkedIn", s, b)
        s, me, _ = call("GET", "https://api.linkedin.com/v2/userinfo", headers={"Authorization": "Bearer " + b["access_token"]})
        if s != 200 or not isinstance(me, dict) or not me.get("sub"):
            raise _err("LinkedIn", s, me)
        return [{"handle": _slug_handle(me.get("name") or "linkedin_member"), "external_id": "person:" + str(me["sub"])[:100],
                 "token": {"access_token": b["access_token"], "refresh_token": b.get("refresh_token")}, "expires_at": None, "scopes": ["w_member_social"]}]

    def execute(self, ctx):
        if ctx.media():
            raise HandError("refused: LinkedIn media is not in v1 (text posts only)")
        tok = ctx.token()
        env = ctx.connector.get("_env") or {}
        author = "urn:li:" + ctx.account["external_id"]          # person:<id> (organization:<id> needs the Community Management API)
        body = {"author": author, "commentary": ctx.text()[:3000], "visibility": "PUBLIC", "lifecycleState": "PUBLISHED", "isReshareDisabledByAuthor": False,
                "distribution": {"feedDistribution": "MAIN_FEED", "targetEntities": [], "thirdPartyDistributionChannels": []}}
        s, b, h = ctx.http("POST", "https://api.linkedin.com/rest/posts", json_body=body, headers={
            "Authorization": "Bearer " + tok["access_token"], "LinkedIn-Version": env.get("HANDS_LINKEDIN_VERSION") or linkedin_version(),
            "X-Restli-Protocol-Version": "2.0.0"})
        pid = {k.lower(): v for k, v in (h or {}).items()}.get("x-restli-id")
        if s != 201 or not pid:
            raise _err("LinkedIn", s, b)
        return str(pid)


# ------------------------------------------------------------------------------------------------------------------- Email (existing outbox)
class Email(Adapter):
    """Drafts into the EXISTING outbox only. The outbox approval (/drafts), the outreach gate, CASL consent, the do-not-contact flag and both suppression
    lists (outreach_send_allowed, checked again by hq_mail immediately before the provider call) decide whether it is ever sent. Never a cold list."""
    slug, title, auth = "email", "Email (existing outbox, CASL consent and suppression enforced)", "api_key"
    actions, signup, max_actions_per_day = ("send",), "none", 20
    terms = "Only drafts into the existing outbox: consent, suppression and the outreach gate decide every send; never a cold list"

    def execute(self, ctx):
        p = ctx.payload
        lead = str(p.get("lead_id") or "")
        if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", lead):
            raise HandError("refused: an email goes to a lead in the CRM (lead_id), never to a typed address")
        rows = ctx.rpc("GET", f"/rest/v1/leads?id=eq.{lead}&select=id,venture_id,email,do_not_contact,consent_basis&limit=1") or []
        if not rows or not rows[0].get("email"):
            raise HandError("refused: lead not found or has no email")
        row = rows[0]
        if row.get("do_not_contact"):
            raise HandError("refused: the lead is marked do-not-contact")
        if not row.get("consent_basis"):
            raise HandError("refused: no recorded consent basis for this lead (CASL)")
        sup = ctx.rpc("POST", "/rest/v1/rpc/is_suppressed", {"p_address": row["email"]})
        if sup is not False:
            raise HandError("refused: the address is suppressed (or the check failed)")
        key = "hands-" + str(ctx.action["id"])
        ctx.rpc("POST", "/rest/v1/outbox", {"venture_id": row.get("venture_id"), "agent": "jarvis-hands", "channel": "email", "to_ref": row["email"], "lead_id": lead,
                                            "status": "draft", "needs_owner": True, "idempotency_key": key,
                                            "body": f"Subject: {str(p.get('subject') or '')[:200]}\n\n{str(p.get('text') or '')[:3000]}"})
        return "outbox:" + key


# ------------------------------------------------------------------------------------------------------------------- Netlify (static deploy)
class Netlify(Adapter):
    slug, title, auth = "netlify", "Netlify static site deploy", "api_key"
    actions, max_actions_per_day = ("create_account", "deploy"), 3
    terms = "The Chairman signs up himself; deploys a zip he approved to a site he connected; free tier"

    def execute(self, ctx):
        page = ctx.payload.get("html")
        if isinstance(page, str) and page.strip():
            # a single self-contained page (the FF Marketing landing page, approved by its hash): zipped in memory as index.html
            import io
            import zipfile
            if len(page.encode()) > 200 * 1024:
                raise HandError("refused: the page is larger than 200 KB")
            buf = io.BytesIO()
            with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
                zf.writestr("index.html", page)
            raw = buf.getvalue()
        else:
            z = str(ctx.payload.get("zip_url") or "")
            if not z.startswith("https://"):
                raise HandError("refused: a deploy needs zip_url (https) or html")
            s, raw, _ = ctx.http("GET", z, timeout=120)
            if s != 200 or not isinstance(raw, (bytes, bytearray)) or not raw.startswith(b"PK") or len(raw) > 50 * 1024 * 1024:
                raise HandError(f"could not fetch a zip to deploy (HTTP {s})")
        site = ctx.account["external_id"]
        # Web Studio previews are Netlify DRAFT deploys (a preview URL, the live site untouched); a publish is a normal (production) deploy
        draft = "?draft=true" if ctx.payload.get("draft") is True else ""
        s, b, _ = ctx.http("POST", f"https://api.netlify.com/api/v1/sites/{urllib.parse.quote(site)}/deploys{draft}",
                           headers={"Authorization": "Bearer " + ctx.token()["api_key"], "Content-Type": "application/zip"}, data=bytes(raw), timeout=300)
        if s not in (200, 201) or not isinstance(b, dict) or "id" not in b:
            raise _err("Netlify", s, b)
        return str(b.get("deploy_ssl_url") or b.get("deploy_url") or b["id"]) if draft else str(b["id"])


# ------------------------------------------------------------------------------------------------------------------- template for new services
class HttpTemplate(Adapter):
    """TEMPLATE (not registered). To add a service with an HTTP API: copy this class, fill the declarations, implement execute() (and authorize_url/exchange
    for OAuth2), add it to ADAPTERS and add the matching row to hand_connectors in a NEW migration. Both are locked paths: the self-edit pipeline opens a pull
    request and the owner approves it. Rules every adapter keeps: https only via ctx.http; tokens only from ctx.token(); never log, return or put a token in an
    error; public text is screened before execute() is called; return the platform's id."""
    slug, title, auth = "template-http", "Template", "oauth2"
    actions, max_actions_per_day, terms = ("post",), 1, "fill in from the service terms"
    BASE = "https://api.example.invalid/v1"

    def execute(self, ctx):
        s, b, _ = ctx.http("POST", f"{self.BASE}/posts", headers={"Authorization": "Bearer " + ctx.token()["access_token"]}, json_body={"text": ctx.text()})
        if s not in (200, 201) or not isinstance(b, dict) or "id" not in b:
            raise _err("Template", s, b)
        return str(b["id"])


ADAPTERS: dict[str, Adapter] = {a.slug: a for a in (MetaFacebook(), MetaInstagram(), TikTok(), YouTube(), XTwitter(), LinkedIn(), Email(), Netlify())}


def adapter_for(slug: str) -> Adapter:
    a = ADAPTERS.get(slug)
    if a is None:
        raise HandError(f"no adapter for {slug}")
    return a
