"""Jarvis hands v1: the generic action executor over the connector registry (hq_hands_adapters), the vault, official OAuth / API-key connections and the
Telegram commands. DORMANT: nothing runs until the owner registers the hand (public.hands_owner_enable, owner-only) and enables a connector
(public.hands_owner_set_connector); dry_run still turns every approved action into a logged "would ...".

Actions run through ONE path (post, upload, send, update, deploy):
  submit (database checks + personal-data screen)  ->  owner approval (Telegram one-tap, /approve, or an owner standing approval)
  ->  core job queue 'hands.action' (held in dry_run, nothing leased while the core is off or the kill switch is on)
  ->  hands_start (kill switch, mode, connector on, account connected, daily rate limit IN THE DATABASE)
  ->  personal-data scan again (python)  ->  executor gate (hq_executor.run: registry, caps, spend gateway, dry_run)  ->  the adapter  ->  hands_finish (audit)
Account creation is ASSISTED ONLY: Jarvis prepares the details, the Chairman approves and signs up himself on the official page (handoff), records it with
/accounts done, then connects it through the platform's official OAuth / API flow (/connect). No password is ever generated, stored or handled.

Secrets: OAuth / API tokens are written ONLY to the Bitwarden vault (bot.py's client). The database keeps vault ids. No token is logged, sent to a model,
or put in an error message. Nothing in this module is a model tool: the model cannot approve, connect or enable anything.
Reuses: hq_executor (executor gate), hq_core (job queue handler, send_owner, "sir" reply helpers), hq_llm (personal-data scan, drafting), bot.py's vault client.
"""
from __future__ import annotations

import json
import logging
import os
import re
import secrets
import time

import hq
import hq_core
import hq_executor
import hq_hands_adapters as A

logger = logging.getLogger(__name__)
AGENT = "jarvis-hands"
OAUTH_TTL_S = 900
_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def _rpc(name: str, args: dict | None = None):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args or {})


def _rest(method: str, path: str, body=None):
    return hq._request(method, path, body, prefer="return=minimal") if method == "POST" and "/rpc/" not in path else hq._request(method, path, body)


# ------------------------------------------------------------------------------------------------------------------- vault
class Vault:
    """bot.py's Bitwarden Secrets Manager client (configure_vault). Values go in and come out here only; ids are what the database records."""

    def __init__(self, client_factory=None, org_id=None, project_id=None, index=None):
        self.client_factory, self.org_id, self.project_id, self.index = client_factory, org_id, project_id, index

    def configured(self) -> bool:
        return bool(self.client_factory and self.org_id)

    def _client(self):
        c = self.client_factory() if self.client_factory else None
        if c is None:
            raise A.HandError("the vault (Bitwarden) is not configured; nothing secret can be stored, so nothing was done")
        return c

    def store(self, name: str, value, note: str = "") -> str:
        v = value.reveal() if isinstance(value, A.Secret) else str(value)
        resp = self._client().secrets().create(self.org_id, name[:200], v, note[:400], [self.project_id] if self.project_id else None)
        sid = str(resp.data.id)
        if self.index:
            try:
                self.index(name[:200], sid)
            except Exception:
                logger.warning("vault index not updated for a hands entry")
        return sid

    def get(self, sid: str) -> str:
        return self._client().secrets().get(sid).data.value


VAULT = Vault()


def configure_vault(client_factory, org_id, project_id=None, index=None) -> None:
    """Called once by bot.py with its own Bitwarden client factory (_get_bw_client) and vault index writer."""
    global VAULT
    VAULT = Vault(client_factory, org_id, project_id, index)


def _store_token(connector: str, handle: str, token: dict) -> str:
    return VAULT.store(f"hands/{connector}/{handle}/token", A.Secret(json.dumps(token)), f"API token for {connector} @{handle} (Jarvis hands)")


def _load_token(ref: str) -> dict:
    if not ref or not _UUID.match(str(ref)):
        raise A.HandError("the account has no token in the vault; connect it again with /connect")
    return json.loads(VAULT.get(ref))


# ------------------------------------------------------------------------------------------------------------------- the executor
def _public_text(action: dict) -> str:
    p = action.get("payload") or {}
    return " ".join(str(p.get(k) or "") for k in ("text", "title", "description", "caption"))


def personal_data(text: str) -> bool:
    import hq_llm
    return hq_llm.has_personal_data(text)


def _env_for(connector: dict) -> dict:
    keys = ("META_APP_ID", "META_APP_SECRET", "TIKTOK_CLIENT_KEY", "TIKTOK_CLIENT_SECRET", "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "X_CLIENT_ID", "X_CLIENT_SECRET",
            "LINKEDIN_CLIENT_ID", "LINKEDIN_CLIENT_SECRET", "HANDS_OAUTH_REDIRECT", "HANDS_LINKEDIN_VERSION")
    return {k: os.environ[k] for k in keys if os.environ.get(k)}


def _safe(e: BaseException) -> str:
    """Error text for the database / Telegram: our own HandError messages, or just the exception type (a library message could carry a secret)."""
    return str(e)[:280] if isinstance(e, A.HandError) else type(e).__name__


def run_action(action_id: str, job: dict | None = None, rpc=None, rest=None, executor_run=None, http=None) -> dict:
    """The worker's handler for 'hands.action'. Returns {'status': ...}. Never raises for a refusal: refusals are recorded, so the queue does not retry them."""
    rpc = rpc or _rpc
    rest = rest or _rest
    executor_run = executor_run or hq_executor.run
    s = rpc("hands_start", {"p_id": action_id}) or {}
    if not s.get("ok"):
        return {"status": "deferred" if s.get("deferred") else ("dry_run" if s.get("dry_run") else "refused"), "reason": s.get("reason")}
    action, connector, account = s["action"], dict(s["connector"]), s.get("account")
    connector["_env"] = _env_for(connector)
    kind = action["action"]

    def finish(status, ref=None, result=None):
        rpc("hands_finish", {"p_id": action_id, "p_status": status, "p_external_ref": ref, "p_result": result})
        return {"status": status, "ref": ref, "result": result}

    if kind in A.PUBLIC_ACTIONS and personal_data(_public_text(action)):
        return finish("failed", result="refused: the text looks like personal data; nothing was published")
    try:
        adapter = A.adapter_for(connector["slug"])
    except A.HandError as e:
        return finish("failed", result=_safe(e))

    def save_token(tok):
        ref = _store_token(connector["slug"], account["handle"], tok)
        rpc("hands_token_refreshed", {"p_account": account["id"], "p_token_vault_ref": ref, "p_expires_at": None})

    ctx = A.Ctx(action=action, account=account, connector=connector, http=http or A.http,
                token=lambda: _load_token((account or {}).get("token_vault_ref")), save_token=save_token, rpc=lambda m, p, b=None: rest(m, p, b))
    executor = "hands-actions"
    try:
        out = executor_run(executor, AGENT, s["task_id"], int(s.get("est_cents") or 1), f"hands {kind} on {connector['slug']}",
                           lambda run_id: (adapter.execute(ctx), 0))
    except hq_executor.ExecutorRefused as e:
        return finish("failed", result=f"executor gate refused: {str(e)[:200]}")
    except Exception as e:
        logger.warning("hands action %s failed: %s", action_id[:8], _safe(e))
        return finish("failed", result=_safe(e))
    if out.get("dry_run"):
        return finish("dry_run", result=f"dry run: would {kind.replace('_', ' ')} on {connector['slug']}; nothing was sent")
    ref = str(out.get("result") or "")
    ref = ref if re.fullmatch(r"[A-Za-z0-9:._/-]{1,200}", ref) else None
    return finish("done", ref=ref, result=f"{kind} done")


@hq_core.handler("hands.action")
def _action_job(job: dict) -> dict:
    aid = str((job.get("payload") or {}).get("action_id") or "")
    if not _UUID.match(aid):
        raise ValueError("hands.action needs payload.action_id")
    run_action(aid, job)
    return {"cents": 0, "ai": False}


@hq_core.handler("hands.draft")
def _draft_job(job: dict) -> dict:
    """Jarvis drafts a post for a division: payload {connector, account_id, action, text | prompt, media, title, scheduled_at, ai_generated}.
    A prompt goes through the private model route (hq_llm, sources 'job:hands.draft'); the draft then waits for the owner like any other action."""
    p = job.get("payload") or {}
    text, cents, ai = p.get("text"), 0, False
    if not text and p.get("prompt"):
        import hq_llm
        system, msgs, _ = hq_llm.build_messages(hq_core.IDENTITY, "", [], "Write the post only, no preamble. " + str(p["prompt"])[:3000])
        r = hq_llm.cached_complete(system, msgs, division=job["division"], task_class="hands.draft", tier="small", sources=["identity", "job:hands.draft"],
                                   contains_client_data=False, on_attempt=lambda: hq_core.extend_lease(job))
        text, cents, ai = (r.get("text") or "").strip(), r.get("cents", 0), True
    if not text:
        raise ValueError("hands.draft needs text or prompt")
    submit(p.get("connector"), p.get("account_id"), p.get("action") or "post", {"text": text, "media": p.get("media") or [], "title": p.get("title")},
           p.get("scheduled_at"), bool(p.get("ai_generated", True)), by="jarvis")
    return {"cents": cents, "ai": ai}


# ------------------------------------------------------------------------------------------------------------------- proposals and decisions
def propose_account(connector: str, division: str, handle: str, display_name: str, purpose: str, bio: str = "", asset_ref: str | None = None,
                    monthly_cents: int = 0, by: str = "jarvis", rpc=None) -> str:
    r = (rpc or _rpc)("hands_propose_account", {"p_connector": connector, "p_division": division, "p_handle": handle, "p_display_name": display_name or None,
                                                "p_purpose": purpose, "p_bio": bio or None, "p_asset_ref": asset_ref, "p_monthly_cents": int(monthly_cents or 0),
                                                "p_by": by}) or {}
    return (f"Proposed; the owner decides (action {str(r['action_id'])[:8]})." if r.get("ok") else f"Not proposed: {r.get('reason', 'refused')}")


def submit(connector, account_id, action, payload: dict, scheduled_at=None, ai_generated=True, by="jarvis", rpc=None) -> dict:
    payload = {k: v for k, v in (payload or {}).items() if v not in (None, "", [])}
    if action in A.PUBLIC_ACTIONS and personal_data(_public_text({"payload": payload})):
        return {"ok": False, "reason": "refused: the text looks like personal data"}
    return (rpc or _rpc)("hands_submit_action", {"p_connector": connector, "p_account": account_id, "p_action": action, "p_payload": payload,
                                                 "p_scheduled_at": scheduled_at, "p_ai_generated": bool(ai_generated), "p_by": by}) or {}


def decide(action_id: str, approved: bool, by: str = "owner:telegram", rpc=None) -> str:
    """Owner-only callers: the Telegram one-tap (hq_commands.apply_decision) and /approve."""
    try:
        r = (rpc or _rpc)("hands_decide", {"p_id": action_id, "p_approved": bool(approved), "p_by": by}) or {}
    except Exception as e:
        return f"Could not record the decision: {type(e).__name__}"
    if not r.get("ok"):
        return f"Not changed: {r.get('reason', 'refused')}."
    st = r.get("status")
    if st == "handoff":
        return handoff_text(action_id, r.get("signup_url"), rpc=rpc)
    return {"rejected": "Rejected; nothing will be done.", "dry_run": "Approved. Dry-run mode: logged as 'would do', nothing was sent.",
            "scheduled": "Approved and scheduled.", "approved": "Approved." + ("" if r.get("queued") else " It waits until the hand and the connector are switched on.")}.get(st, f"Recorded: {st}.")


def handoff_text(action_id: str, signup_url: str | None, rpc=None, get=None) -> str:
    """The guided handoff: everything prepared, the Chairman signs up himself on the official page. No password is generated, stored or sent:
    his credentials stay with him and the platform. Jarvis takes over only through the official OAuth / API connection (/connect)."""
    get = get or (lambda p: hq._request("GET", p))
    rows = get(f"/rest/v1/hand_actions?id=eq.{action_id}&select=account_id,connector&limit=1") or []
    acc = (get(f"/rest/v1/hand_accounts?id=eq.{rows[0]['account_id']}&select=id,handle,display_name,bio,asset_ref&limit=1") or [{}])[0] if rows else {}
    conn = rows[0]["connector"] if rows else "<connector>"
    return (f"Sir, approved. Please sign up yourself on the official page: {signup_url or 'the sign-up page'}\n"
            f"Handle: @{acc.get('handle', '?')}\nName: {acc.get('display_name') or '-'}\nBio: {acc.get('bio') or '-'}"
            + (f"\nProfile image: {acc['asset_ref']}" if acc.get("asset_ref") else "")
            + f"\nKeep the password yourself (I never store it). Then send /accounts done {str(acc.get('id', ''))[:8]} and /connect {conn} <division> so I can post through the official API.")


# ------------------------------------------------------------------------------------------------------------------- OAuth / API-key connections
_STATES: dict[str, dict] = {}


def connect_start(connector: str, division: str, env: dict | None = None) -> str:
    env = env if env is not None else _env_for({})
    a = A.adapter_for(connector)
    if a.auth != "oauth2":
        raise A.HandError(f"{connector} connects with an API key: /connect {connector} <division> <site-or-handle> <key>")
    state, verifier = secrets.token_urlsafe(24), secrets.token_urlsafe(48)
    _STATES[state] = {"connector": connector, "division": division, "verifier": verifier, "expires": time.time() + OAUTH_TTL_S}
    return a.authorize_url(state, verifier, env)


def connect_finish(connector: str, pasted_url: str, env: dict | None = None, call=None, rpc=None, by="owner:telegram") -> str:
    from urllib.parse import parse_qs, urlparse
    env = env if env is not None else _env_for({})
    q = parse_qs(urlparse(pasted_url.strip()).query)
    state, code = (q.get("state") or [""])[0], (q.get("code") or [""])[0]
    st = _STATES.pop(state, None)
    if not st or st["expires"] < time.time() or st["connector"] != connector:
        return "That link does not match a connection I started (or it expired). Send /connect again."
    if not code:
        return "No authorization code in that link (consent was refused?). Nothing was stored."
    found = A.adapter_for(connector).exchange(code, st["verifier"], env, call or A.http)
    names = []
    for f in found:
        ref = _store_token(connector, f["handle"], f["token"])
        r = (rpc or _rpc)("hands_connect", {"p_connector": connector, "p_division": st["division"], "p_handle": f["handle"], "p_external_id": f["external_id"],
                                            "p_token_vault_ref": ref, "p_expires_at": f.get("expires_at"), "p_scopes": f.get("scopes") or [], "p_by": by}) or {}
        names.append(f"@{f['handle']}" + ("" if r.get("ok") else f" (not recorded: {r.get('reason')})"))
    return f"Connected {connector}: {', '.join(names)}. Tokens are in the vault only."


def connect_key(connector: str, division: str, handle: str, external_id: str, key: str, rpc=None, by="owner:telegram") -> str:
    a = A.adapter_for(connector)
    if a.auth != "api_key":
        return f"{connector} connects with /connect {connector} <division> (OAuth)."
    ref = _store_token(connector, handle, {"api_key": key})
    r = (rpc or _rpc)("hands_connect", {"p_connector": connector, "p_division": division, "p_handle": handle, "p_external_id": external_id,
                                        "p_token_vault_ref": ref, "p_expires_at": None, "p_scopes": [], "p_by": by}) or {}
    return f"Connected {connector} @{handle}. The key is in the vault only." if r.get("ok") else f"Not connected: {r.get('reason')}"


def youtube_device_start(env: dict | None = None, call=None) -> dict:
    """YouTube uses Google's device flow (like /connectcalendar): no redirect page needed. -> {device_code, user_code, verification_url, interval}."""
    env = env if env is not None else _env_for({})
    cid, = A._need(env, "GOOGLE_CLIENT_ID")
    s, b, _ = (call or A.http)("POST", "https://oauth2.googleapis.com/device/code", form={"client_id": cid, "scope": A.YouTube.SCOPE})
    if s != 200 or not isinstance(b, dict) or "device_code" not in b:
        raise A._err("Google", s, b)
    return b


def youtube_device_poll(device_code: str, division: str, env: dict | None = None, call=None, rpc=None, by="owner:telegram") -> str | None:
    """One poll. None while the owner has not approved yet."""
    env = env if env is not None else _env_for({})
    call = call or A.http
    cid, secret = A._need(env, "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET")
    s, b, _ = call("POST", "https://oauth2.googleapis.com/token", form={"client_id": cid, "client_secret": secret, "device_code": device_code,
                                                                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
    if isinstance(b, dict) and b.get("error") in ("authorization_pending", "slow_down"):
        return None
    if s != 200 or not isinstance(b, dict) or not b.get("refresh_token"):
        raise A._err("Google", s, b)
    s2, ch, _ = call("GET", "https://www.googleapis.com/youtube/v3/channels?part=id,snippet&mine=true", headers={"Authorization": "Bearer " + b["access_token"]})
    items = (ch or {}).get("items") or [] if isinstance(ch, dict) else []
    if not items:
        raise A.HandError("that Google account has no YouTube channel")
    c = items[0]
    handle = A._slug_handle((c.get("snippet") or {}).get("customUrl") or (c.get("snippet") or {}).get("title"))
    ref = _store_token("youtube", handle, {"refresh_token": b["refresh_token"]})
    r = (rpc or _rpc)("hands_connect", {"p_connector": "youtube", "p_division": division, "p_handle": handle, "p_external_id": str(c["id"]),
                                        "p_token_vault_ref": ref, "p_expires_at": None, "p_scopes": A.YouTube.SCOPE.split(), "p_by": by}) or {}
    return f"Connected YouTube channel @{handle}. The token is in the vault only." if r.get("ok") else f"Not connected: {r.get('reason')}"


# ------------------------------------------------------------------------------------------------------------------- Telegram (owner only)
def _owner(update) -> bool:
    return hq_core._is_owner(update)


def _resolve(table: str, short: str, get=None) -> str | None:
    short = re.sub(r"[^0-9a-f]", "", (short or "").lower())[:8]
    if len(short) < 6:
        return None
    rows = (get or (lambda p: hq._request("GET", p)))(f"/rest/v1/{table}?id=gte.{short.ljust(8, '0')}-0000-0000-0000-000000000000"
                                                      f"&id=lte.{short.ljust(8, 'f')}-ffff-ffff-ffff-ffffffffffff&select=id&limit=2") or []
    return rows[0]["id"] if len(rows) == 1 else None


def accounts_text(get=None) -> str:
    get = get or (lambda p: hq._request("GET", p))
    rows = get("/rest/v1/hand_accounts?select=id,connector,handle,division,status&order=created_at.desc&limit=30") or []
    if not rows:
        return ("Sir, no accounts yet. Propose one: /accounts new <connector> <division> <handle> | <purpose> | <bio>\n"
                "Connectors: " + ", ".join(sorted(A.ADAPTERS)) + ".")
    lines = [f"{r['id'][:8]} {r['connector']} @{r['handle']} [{r['division']}] {r['status']}" for r in rows]
    return "Sir, accounts:\n" + "\n".join(lines) + "\n/accounts done <id> [handle] after you sign up yourself; /connect <connector> <division> to hand me posting."


def queue_text(get=None) -> str:
    get = get or (lambda p: hq._request("GET", p))
    rows = get("/rest/v1/hand_actions?status=in.(draft,approved,scheduled,running,handoff,failed,dry_run)&select=id,connector,action,status,scheduled_at,payload,result"
               "&order=created_at.desc&limit=25") or []
    if not rows:
        return "Sir, the queue is empty."
    out = []
    for r in rows:
        t = str((r.get("payload") or {}).get("text") or (r.get("payload") or {}).get("title") or "")[:60].replace("\n", " ")
        out.append(f"{r['id'][:8]} {r['connector']} {r['action']} {r['status']}" + (f" @{r['scheduled_at'][:16]}" if r.get("scheduled_at") else "")
                   + (f": {t}" if t else "") + (f" ({str(r['result'])[:60]})" if r.get("result") and r["status"] in ("failed", "dry_run") else ""))
    return "Sir, the queue:\n" + "\n".join(out) + "\n/approve <id> (or /approve <id> no), /post <id> to run an approved one now."


async def _reply(update, text):
    await hq_core.reply(update, text[:4000])


async def accounts_cmd(update, context) -> None:
    """/accounts | /accounts new <connector> <division> <handle> | <purpose> | <bio> | /accounts done <id> [handle]"""
    if not _owner(update):
        return
    import asyncio
    args = list(context.args or [])
    try:
        if args and args[0].lower() == "new" and len(args) >= 4:
            rest = " ".join(args[4:]).split("|")
            purpose = (rest[1] if len(rest) > 1 else rest[0]).strip()
            bio = rest[2].strip() if len(rest) > 2 else ""
            text = await asyncio.to_thread(propose_account, args[1], args[2], args[3].lstrip("@"), rest[0].strip() if len(rest) > 1 else "", purpose, bio, by="owner:telegram")
        elif args and args[0].lower() == "done" and len(args) >= 2:
            aid = await asyncio.to_thread(_resolve, "hand_accounts", args[1])
            r = (await asyncio.to_thread(_rpc, "hands_account_done", {"p_account": aid, "p_handle": args[2].lstrip("@") if len(args) > 2 else None, "p_by": "owner:telegram"})) if aid else {}
            text = "Recorded, sir. Now /connect it so I can post." if (r or {}).get("ok") else f"Not recorded: {(r or {}).get('reason', 'no such account')}."
        else:
            text = await asyncio.to_thread(accounts_text)
    except Exception as e:
        text = f"Accounts are not available: {type(e).__name__} (migration pending?)."
    await _reply(update, text)


async def connect_cmd(update, context) -> None:
    """/connect <connector> <division>            -> consent link (YouTube: device code)
       /connect <connector> <division> <pasted redirect URL>
       /connect <api-key connector> <division> <site-or-handle> <key> (the message is deleted)"""
    if not _owner(update):
        return
    import asyncio
    args = list(context.args or [])
    if len(args) < 2:
        await _reply(update, "Usage: /connect <connector> <division> [pasted link]. Connectors: " + ", ".join(s for s, a in A.ADAPTERS.items() if a.auth in ("oauth2", "api_key")))
        return
    conn, div = args[0].lower(), args[1].lower()
    try:
        a = A.adapter_for(conn)
        if a.auth == "api_key" and len(args) >= 4:
            try:
                await update.message.delete()      # the key must not stay in the chat
            except Exception:
                pass
            text = await asyncio.to_thread(connect_key, conn, div, args[2].lstrip("@"), args[2], args[3])
        elif conn == "youtube":
            d = await asyncio.to_thread(youtube_device_start)
            text = f"Sir, open {d.get('verification_url')} and enter {d.get('user_code')}. I will finish the connection when you approve."

            async def _poll():
                for _ in range(int(d.get("expires_in", 900)) // max(5, int(d.get("interval", 5)))):
                    await asyncio.sleep(max(5, int(d.get("interval", 5))))
                    try:
                        msg = await asyncio.to_thread(youtube_device_poll, d["device_code"], div)
                    except Exception as e:
                        msg = f"YouTube connection failed: {A.HandError(str(e)) if isinstance(e, A.HandError) else type(e).__name__}"
                    if msg:
                        await hq_core.send_to(context.bot, update.effective_chat.id, msg)
                        return
            asyncio.create_task(_poll())
        elif len(args) >= 3 and args[2].startswith("https://"):
            try:
                await update.message.delete()
            except Exception:
                pass
            text = await asyncio.to_thread(connect_finish, conn, args[2])
        else:
            url = await asyncio.to_thread(connect_start, conn, div)
            text = f"Sir, open this to connect {conn} (you approve on the platform; you never give me your password): {url}\nWhen it lands on the redirect page, send /connect {conn} {div} <that page's full link>."
    except A.HandError as e:
        text = f"Sir, not connected: {e}"
    except Exception as e:
        text = f"Sir, not connected: {type(e).__name__}."
    await _reply(update, text)


async def queue_cmd(update, context) -> None:
    if not _owner(update):
        return
    import asyncio
    try:
        text = await asyncio.to_thread(queue_text)
    except Exception as e:
        text = f"The queue is not available: {type(e).__name__} (migration pending?)."
    await _reply(update, text)


async def approve_cmd(update, context) -> None:
    """/approve <id> [no]"""
    if not _owner(update):
        return
    import asyncio
    args = list(context.args or [])
    aid = await asyncio.to_thread(_resolve, "hand_actions", args[0]) if args else None
    if not aid:
        await _reply(update, "Usage: /approve <id> [no]. See /queue.")
        return
    await _reply(update, await asyncio.to_thread(decide, aid, not (len(args) > 1 and args[1].lower() in ("no", "reject", "n")), "owner:telegram:/approve"))


async def post_cmd(update, context) -> None:
    """/post <id>: run an approved action now."""
    if not _owner(update):
        return
    import asyncio
    args = list(context.args or [])
    aid = await asyncio.to_thread(_resolve, "hand_actions", args[0]) if args else None
    if not aid:
        await _reply(update, "Usage: /post <id>. See /queue.")
        return
    try:
        r = await asyncio.to_thread(_rpc, "hands_run_now", {"p_id": aid, "p_by": "owner:telegram:/post"}) or {}
        text = {"dry_run": "Dry-run mode: logged as 'would post', nothing was sent.", "approved": "Queued now." if r.get("queued") else "Approved, but the hand or connector is off."}.get(
            r.get("status"), f"Not run: {r.get('reason', r.get('status'))}.") if r.get("ok") else f"Not run: {r.get('reason')}."
    except Exception as e:
        text = f"Not run: {type(e).__name__}."
    await _reply(update, text)


COMMANDS = (("accounts", accounts_cmd), ("connect", connect_cmd), ("queue", queue_cmd), ("approve", approve_cmd), ("post", post_cmd))


def register(app, CommandHandler) -> None:
    for name, fn in COMMANDS:
        app.add_handler(CommandHandler(name, fn))
