"""Jarvis hands v1 (hq_hands, hq_hands_adapters). No network, no vault: platform APIs, the database RPCs and Bitwarden are mocked."""
import asyncio
import json
import logging
import os
import re
import unittest
from datetime import date
from unittest import mock

import hq_executor
import hq_hands as H
import hq_hands_adapters as A

ROOT = os.path.dirname(os.path.abspath(__file__))
MIG = os.path.join(ROOT, "migrations", "20261124_jarvis_hands_v1.sql")
TOKEN = "tok-abc123-not-for-logs"
ACT = "11111111-2222-4333-8444-555555555555"


def _read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class FakeVault:
    def __init__(self):
        self.items = {}

    def configured(self):
        return True

    def store(self, name, value, note=""):
        sid = f"{len(self.items) + 1:08x}-1111-4222-8333-444455556666"
        self.items[sid] = (name, value.reveal() if isinstance(value, A.Secret) else value)
        return sid

    def get(self, sid):
        return self.items[sid][1]


class Http:
    """Scripted API: (method, url prefix) -> (status, body, headers) or a callable. Records every call."""
    def __init__(self, routes):
        self.routes, self.calls = routes, []

    def __call__(self, method, url, headers=None, json_body=None, form=None, data=None, timeout=60):
        call = {"method": method, "url": url, "headers": headers or {}, "json": json_body, "form": form, "data": data}
        self.calls.append(call)
        for (m, prefix), resp in self.routes.items():
            if m == method and url.startswith(prefix):
                return resp(call) if callable(resp) else resp
        raise AssertionError(f"unexpected call {method} {url}")


class Rpc:
    def __init__(self, start=None, **answers):
        self.calls, self.start, self.answers = [], start, answers

    def __call__(self, name, args=None):
        self.calls.append((name, args or {}))
        if name == "hands_start":
            return self.start
        return self.answers.get(name, {"ok": True})

    def last(self, name):
        return [a for n, a in self.calls if n == name][-1]


def started(connector="meta-instagram", action="post", payload=None, ai=True, account=True, **conn):
    c = {"slug": connector, "title": connector, "ai_label": A.adapter_for(connector).ai_label, "enabled": True, **conn}
    acc = {"id": "acc-1", "handle": "donna_hq", "division": "donna", "status": "connected", "external_id": "1789", "token_vault_ref": None} if account else None
    return {"ok": True, "task_id": "task-1", "est_cents": 1, "connector": c, "account": acc,
            "action": {"id": ACT, "action": action, "payload": payload or {"text": "Spring offer", "media": ["https://cdn.example.invalid/a.jpg"]},
                       "ai_generated": ai, "account_id": "acc-1" if account else None}}


def live_executor(calls=None):
    def run(executor, agent, task, est, purpose, work):
        (calls if calls is not None else []).append((executor, agent, task, est))
        result, _ = work("run-1")
        return {"status": "done", "dry_run": False, "run_id": "run-1", "result": result}
    return run


class Base(unittest.TestCase):
    def setUp(self):
        self.vault = FakeVault()
        p = mock.patch.object(H, "VAULT", self.vault)
        p.start()
        self.addCleanup(p.stop)
        q = mock.patch.object(H, "personal_data", lambda t: bool(re.search(r"\d{3}[ -]\d{3}[ -]\d{4}|@\w+\.\w+", t)))
        q.start()
        self.addCleanup(q.stop)

    def connected(self, start, token):
        ref = self.vault.store("t", json.dumps(token))
        start["account"]["token_vault_ref"] = ref
        return start


# ------------------------------------------------------------------------------------------------------------------- registry
class RegistryTests(unittest.TestCase):
    def seed(self):
        sql = _read(MIG)
        block = sql[sql.index("insert into public.hand_connectors"):sql.index("on conflict (slug) do update")]
        rows = re.findall(r"\('([a-z-]+)', '([^']*)', '(oauth2|api_key|none)', (array\[[^\]]*\]|'\{\}'), '(assisted|none)', (\d+), (\d+), '(api_field|caption|none)', (?:'[^']*'|null),\s*'([^']*)'\)", block)
        return {r[0]: r for r in rows}

    def test_database_seed_matches_adapters(self):
        rows = self.seed()
        self.assertEqual(set(rows), set(A.ADAPTERS))
        for slug, a in A.ADAPTERS.items():
            _, title, auth, actions, signup, maxd, cost, label, terms = rows[slug]
            self.assertEqual(title, a.title, slug)
            self.assertEqual(auth, a.auth, slug)
            self.assertEqual(sorted(re.findall(r"'([a-z_]+)'", actions)), sorted(a.actions), slug)
            self.assertEqual(signup, a.signup, slug)
            self.assertEqual(int(maxd), a.max_actions_per_day, slug)
            self.assertEqual(int(cost), a.cost_cents_per_action, slug)
            self.assertEqual(label, a.ai_label, slug)
            self.assertEqual(terms, a.terms, slug)

    def test_sign_up_is_assisted_or_none_everywhere(self):
        for a in A.ADAPTERS.values():
            self.assertIn(a.signup, ("assisted", "none"), a.slug)
        self.assertIn("check (signup_mode in ('assisted', 'none'))", _read(MIG))

    def test_template_not_registered_and_actions_known(self):
        self.assertNotIn("template-http", A.ADAPTERS)
        for a in A.ADAPTERS.values():
            self.assertTrue(set(a.actions) <= set(A.ACTIONS), a.slug)
        with self.assertRaises(A.HandError):
            A.adapter_for("template-http")

    def test_required_platforms_present(self):
        for s in ("meta-facebook", "meta-instagram", "tiktok", "youtube", "x-twitter", "linkedin", "email", "netlify"):
            self.assertIn(s, A.ADAPTERS)

    def test_no_model_tool_reaches_the_hands(self):
        bot = _read(os.path.join(ROOT, "bot.py"))
        for name in ("hands_decide", "hands_owner_enable", "hands_connect", "hands_run_now", "hq_hands.decide", "hq_hands.submit"):
            self.assertNotIn(name, bot)

    def test_api_calls_never_follow_redirects(self):
        self.assertIsNone(A._NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://elsewhere.example.invalid/"))

    def test_secret_repr_hides_value(self):
        s = A.Secret(TOKEN)
        self.assertNotIn(TOKEN, repr(s) + str(s) + f"{s}")
        self.assertEqual(s.reveal(), TOKEN)


# ------------------------------------------------------------------------------------------------------------------- executor path
class RunActionTests(Base):
    def test_posting_state_machine_done(self):
        st = self.connected(started(), {"access_token": TOKEN})
        rpc = Rpc(start=st)
        http = Http({("POST", f"{A.GRAPH}/1789/media_publish"): (200, {"id": "IGPOST1"}, {}),
                     ("POST", f"{A.GRAPH}/1789/media"): (200, {"id": "CONT1"}, {})})
        calls = []
        out = H.run_action(ACT, rpc=rpc, executor_run=live_executor(calls), http=http)
        self.assertEqual(out["status"], "done")
        self.assertEqual(rpc.last("hands_finish"), {"p_id": ACT, "p_status": "done", "p_external_ref": "IGPOST1", "p_result": "post done"})
        self.assertEqual(calls, [("hands-actions", "jarvis-hands", "task-1", 1)])
        self.assertEqual(http.calls[0]["form"]["image_url"], "https://cdn.example.invalid/a.jpg")
        self.assertIn(A.AI_CAPTION, http.calls[0]["form"]["caption"])
        self.assertEqual(http.calls[1]["form"]["creation_id"], "CONT1")

    def test_refusals_from_the_database_call_nothing(self):
        for start, status in (({"ok": False, "reason": "kill switch is on"}, "refused"), ({"ok": False, "dry_run": True}, "dry_run"),
                              ({"ok": False, "deferred": True, "until": "x"}, "deferred"), ({"ok": False, "reason": "status draft"}, "refused")):
            rpc = Rpc(start=start)
            http = Http({})
            ex = mock.Mock()
            out = H.run_action(ACT, rpc=rpc, executor_run=ex, http=http)
            self.assertEqual(out["status"], status)
            ex.assert_not_called()
            self.assertEqual(http.calls, [])
            self.assertEqual([n for n, _ in rpc.calls], ["hands_start"])

    def test_executor_dry_run_sends_nothing(self):
        rpc = Rpc(start=self.connected(started(), {"access_token": TOKEN}))
        http = Http({})
        out = H.run_action(ACT, rpc=rpc, http=http, executor_run=lambda *a: {"status": "dry_run", "dry_run": True, "run_id": "r", "result": None})
        self.assertEqual(out["status"], "dry_run")
        self.assertEqual(http.calls, [])
        self.assertTrue(rpc.last("hands_finish")["p_result"].startswith("dry run: would post"))

    def test_executor_gate_refusal_recorded(self):
        def refuse(*a):
            raise hq_executor.ExecutorRefused("kill switch is on")
        rpc = Rpc(start=self.connected(started(), {"access_token": TOKEN}))
        out = H.run_action(ACT, rpc=rpc, executor_run=refuse, http=Http({}))
        self.assertEqual(out["status"], "failed")
        self.assertIn("executor gate refused: kill switch is on", rpc.last("hands_finish")["p_result"])

    def test_personal_data_refused_before_any_call(self):
        rpc = Rpc(start=self.connected(started(payload={"text": "Call Jane at 613 555 0199", "media": ["https://cdn.example.invalid/a.jpg"]}), {"access_token": TOKEN}))
        ex, http = mock.Mock(), Http({})
        out = H.run_action(ACT, rpc=rpc, executor_run=ex, http=http)
        self.assertEqual(out["status"], "failed")
        self.assertTrue(rpc.last("hands_finish")["p_result"].startswith("refused: the text looks like personal data"))
        ex.assert_not_called()
        self.assertEqual(http.calls, [])

    def test_platform_error_fails_without_leaking_token(self):
        rpc = Rpc(start=self.connected(started(), {"access_token": TOKEN}))
        http = Http({("POST", f"{A.GRAPH}/1789/media"): (400, {"error": {"message": "Invalid parameter"}}, {})})
        with self.assertLogs("hq_hands", level=logging.WARNING) as logs:
            out = H.run_action(ACT, rpc=rpc, executor_run=live_executor(), http=http)
        self.assertEqual(out["status"], "failed")
        res = rpc.last("hands_finish")["p_result"]
        self.assertIn("HTTP 400", res)
        self.assertNotIn(TOKEN, res + "".join(logs.output) + json.dumps(rpc.calls))

    def test_unexpected_exception_reports_type_only(self):
        rpc = Rpc(start=self.connected(started(), {"access_token": TOKEN}))
        def boom(*a, **k):
            raise RuntimeError("secret " + TOKEN)
        out = H.run_action(ACT, rpc=rpc, executor_run=live_executor(), http=boom)
        self.assertEqual(rpc.last("hands_finish")["p_result"], "RuntimeError")
        self.assertEqual(out["status"], "failed")

    def test_missing_token_is_a_safe_failure(self):
        rpc = Rpc(start=started())
        H.run_action(ACT, rpc=rpc, executor_run=live_executor(), http=Http({}))
        self.assertIn("connect it again", rpc.last("hands_finish")["p_result"])

    def test_job_handler_registered_and_validates(self):
        import hq_core
        self.assertIs(hq_core.HANDLERS["hands.action"], H._action_job)
        self.assertIn("hands.draft", hq_core.HANDLERS)
        with self.assertRaises(ValueError):
            H._action_job({"payload": {"action_id": "nope"}})
        self.assertTrue(hq_core.external_effect({"kind": "hands.action", "payload": {"action_id": ACT, "external": True}}))


# ------------------------------------------------------------------------------------------------------------------- approvals, submit, handoff
class ApprovalTests(Base):
    def test_decide_messages(self):
        for answer, want in (({"ok": True, "status": "dry_run"}, "Dry-run mode"), ({"ok": True, "status": "approved", "queued": False}, "switched on"),
                             ({"ok": True, "status": "scheduled"}, "scheduled"), ({"ok": True, "status": "rejected"}, "Rejected"),
                             ({"ok": False, "reason": "already done"}, "Not changed: already done")):
            rpc = Rpc(hands_decide=answer)
            self.assertIn(want, H.decide(ACT, True, rpc=rpc))
            self.assertEqual(rpc.last("hands_decide"), {"p_id": ACT, "p_approved": True, "p_by": "owner:telegram"})

    def test_handoff_prepares_details_and_stores_no_password(self):
        get = lambda p: ([{"account_id": "acc-1", "connector": "tiktok"}] if "hand_actions" in p
                         else [{"id": "acc-12345678", "handle": "donna_hq", "display_name": "Donna", "bio": "HVAC help", "asset_ref": "https://cdn.example.invalid/logo.png"}])
        text = H.handoff_text(ACT, "https://www.tiktok.com/signup", get=get)
        self.assertTrue(text.startswith("Sir, "))
        for part in ("https://www.tiktok.com/signup", "@donna_hq", "Donna", "HVAC help", "logo.png", "/accounts done acc-1234", "/connect tiktok"):
            self.assertIn(part, text)
        self.assertEqual(self.vault.items, {})
        self.assertIn("never store it", text)

    def test_decide_handoff_returns_guided_text(self):
        rpc = Rpc(hands_decide={"ok": True, "status": "handoff", "signup_url": "https://x.com/i/flow/signup"})
        with mock.patch.object(H, "handoff_text", return_value="Sir, sign up") as h:
            self.assertEqual(H.decide(ACT, True, rpc=rpc), "Sir, sign up")
        h.assert_called_once()

    def test_submit_screens_public_text_and_strips_empty(self):
        rpc = Rpc(hands_submit_action={"ok": True, "status": "draft"})
        r = H.submit("meta-instagram", "acc-1", "post", {"text": "reach me at a@b.com"}, rpc=rpc)
        self.assertFalse(r["ok"])
        self.assertEqual(rpc.calls, [])
        H.submit("meta-instagram", "acc-1", "post", {"text": "Spring offer", "media": [], "title": None}, rpc=rpc)
        self.assertEqual(rpc.last("hands_submit_action")["p_payload"], {"text": "Spring offer"})

    def test_email_send_is_not_screened_as_public(self):
        rpc = Rpc(hands_submit_action={"ok": True, "approval": "no_external_effect"})
        H.submit("email", None, "send", {"lead_id": ACT, "subject": "Hi", "text": "Hello Jane, a@b.com"}, rpc=rpc)
        self.assertEqual(len(rpc.calls), 1)

    def test_propose_account_args(self):
        rpc = Rpc(hands_propose_account={"ok": True, "action_id": ACT})
        out = H.propose_account("youtube", "donna", "donna_hq", "Donna", "channel for the division", rpc=rpc)
        self.assertIn("owner decides", out)
        self.assertNotIn("password", json.dumps(rpc.calls).lower())


# ------------------------------------------------------------------------------------------------------------------- connections
class ConnectTests(Base):
    ENV = {"META_APP_ID": "app", "META_APP_SECRET": "sec", "HANDS_OAUTH_REDIRECT": "https://hq.example.invalid/oauth", "X_CLIENT_ID": "xid", "X_CLIENT_SECRET": "xs",
           "TIKTOK_CLIENT_KEY": "tk", "TIKTOK_CLIENT_SECRET": "ts", "LINKEDIN_CLIENT_ID": "li", "LINKEDIN_CLIENT_SECRET": "ls", "GOOGLE_CLIENT_ID": "g", "GOOGLE_CLIENT_SECRET": "gs"}

    def test_meta_oauth_stores_tokens_in_vault_only(self):
        url = H.connect_start("meta-instagram", "donna", env=self.ENV)
        state = re.search(r"state=([^&]+)", url).group(1)
        self.assertIn("instagram_content_publish", url)
        http = Http({("GET", f"{A.GRAPH}/oauth/access_token"): (200, {"access_token": "short-or-long"}, {}),
                     ("GET", f"{A.GRAPH}/me/accounts"): (200, {"data": [{"id": "55", "name": "Donna HQ", "access_token": TOKEN,
                                                                        "instagram_business_account": {"id": "1789", "username": "donna_hq"}}]}, {})})
        rpc = Rpc(hands_connect={"ok": True})
        out = H.connect_finish("meta-instagram", f"https://hq.example.invalid/oauth?code=C0DE&state={state}", env=self.ENV, call=http, rpc=rpc)
        self.assertIn("Connected meta-instagram: @donna_hq", out)
        args = rpc.last("hands_connect")
        self.assertEqual(args["p_external_id"], "1789")
        self.assertRegex(args["p_token_vault_ref"], r"^[0-9a-f]{8}-")
        self.assertEqual(json.loads(self.vault.get(args["p_token_vault_ref"])), {"access_token": TOKEN})
        self.assertNotIn(TOKEN, json.dumps(rpc.calls) + out)
        # the state is single-use
        self.assertIn("does not match", H.connect_finish("meta-instagram", f"https://hq.example.invalid/oauth?code=C0DE&state={state}", env=self.ENV, call=http, rpc=rpc))

    def test_wrong_or_missing_state_refused(self):
        rpc = Rpc()
        self.assertIn("does not match", H.connect_finish("meta-facebook", "https://hq.example.invalid/oauth?code=x&state=forged", env=self.ENV, call=Http({}), rpc=rpc))
        url = H.connect_start("tiktok", "donna", env=self.ENV)
        state = re.search(r"state=([^&]+)", url).group(1)
        self.assertIn("does not match", H.connect_finish("meta-facebook", f"https://hq.example.invalid/oauth?code=x&state={state}", env=self.ENV, call=Http({}), rpc=rpc))
        self.assertEqual(rpc.calls, [])
        self.assertEqual(self.vault.items, {})

    def test_x_uses_pkce(self):
        url = H.connect_start("x-twitter", "donna", env=self.ENV)
        self.assertIn("code_challenge_method=S256", url)
        state = re.search(r"state=([^&]+)", url).group(1)
        verifier = H._STATES[state]["verifier"]
        http = Http({("POST", "https://api.x.com/2/oauth2/token"): (200, {"access_token": TOKEN, "refresh_token": "r1", "scope": "tweet.write"}, {}),
                     ("GET", "https://api.x.com/2/users/me"): (200, {"data": {"id": "42", "username": "donna"}}, {})})
        H.connect_finish("x-twitter", f"https://hq.example.invalid/oauth?code=c&state={state}", env=self.ENV, call=http, rpc=Rpc())
        self.assertEqual(http.calls[0]["form"]["code_verifier"], verifier)

    def test_unconfigured_oauth_is_refused_clearly(self):
        with self.assertRaises(A.HandError) as e:
            H.connect_start("linkedin", "donna", env={})
        self.assertIn("LINKEDIN_CLIENT_ID", str(e.exception))
        with self.assertRaises(A.HandError):
            H.connect_start("netlify", "donna", env=self.ENV)     # API-key connector

    def test_api_key_connection_goes_to_vault(self):
        rpc = Rpc(hands_connect={"ok": True})
        out = H.connect_key("netlify", "donna", "site-1", "site-1", "nfp_key", rpc=rpc)
        self.assertIn("vault only", out)
        self.assertNotIn("nfp_key", json.dumps(rpc.calls))
        self.assertEqual(json.loads(self.vault.get(rpc.last("hands_connect")["p_token_vault_ref"])), {"api_key": "nfp_key"})

    def test_youtube_device_flow(self):
        http = Http({("POST", "https://oauth2.googleapis.com/device/code"): (200, {"device_code": "D", "user_code": "ABCD", "verification_url": "https://www.google.com/device"}, {})})
        self.assertEqual(H.youtube_device_start(env=self.ENV, call=http)["user_code"], "ABCD")
        pending = Http({("POST", "https://oauth2.googleapis.com/token"): (428, {"error": "authorization_pending"}, {})})
        self.assertIsNone(H.youtube_device_poll("D", "donna", env=self.ENV, call=pending, rpc=Rpc()))
        ok = Http({("POST", "https://oauth2.googleapis.com/token"): (200, {"access_token": "a", "refresh_token": TOKEN}, {}),
                   ("GET", "https://www.googleapis.com/youtube/v3/channels"): (200, {"items": [{"id": "UC1", "snippet": {"title": "Donna HQ"}}]}, {})})
        rpc = Rpc(hands_connect={"ok": True})
        self.assertIn("Connected YouTube channel", H.youtube_device_poll("D", "donna", env=self.ENV, call=ok, rpc=rpc))
        self.assertEqual(json.loads(self.vault.get(rpc.last("hands_connect")["p_token_vault_ref"])), {"refresh_token": TOKEN})


# ------------------------------------------------------------------------------------------------------------------- adapters (mocked HTTP)
class AdapterTests(Base):
    def ctx(self, connector, payload, account=None, ai=True, token=None, http=None, env=None, rpc=None, action="post"):
        c = {"slug": connector, "title": connector, "ai_label": A.adapter_for(connector).ai_label, "_env": env or {}}
        return A.Ctx(action={"id": ACT, "action": action, "payload": payload, "ai_generated": ai}, account=account or {"id": "acc-1", "handle": "h", "external_id": "77"},
                     connector=c, token=lambda: dict(token or {"access_token": TOKEN}), http=http, rpc=rpc, save_token=mock.Mock())

    def test_facebook_text_and_photo(self):
        http = Http({("POST", f"{A.GRAPH}/77/feed"): (200, {"id": "77_1"}, {}), ("POST", f"{A.GRAPH}/77/photos"): (200, {"id": "9", "post_id": "77_2"}, {})})
        self.assertEqual(A.ADAPTERS["meta-facebook"].execute(self.ctx("meta-facebook", {"text": "Hi"}, http=http)), "77_1")
        self.assertIn(A.AI_CAPTION, http.calls[0]["form"]["message"])
        self.assertEqual(A.ADAPTERS["meta-facebook"].execute(self.ctx("meta-facebook", {"text": "Hi", "media": ["https://cdn.example.invalid/p.jpg"]}, ai=False, http=http)), "77_2")
        self.assertNotIn(A.AI_CAPTION, http.calls[1]["form"]["caption"])

    def test_instagram_needs_media_and_https(self):
        with self.assertRaises(A.HandError):
            A.ADAPTERS["meta-instagram"].execute(self.ctx("meta-instagram", {"text": "Hi"}, http=Http({})))
        with self.assertRaises(A.HandError):
            A.ADAPTERS["meta-instagram"].execute(self.ctx("meta-instagram", {"text": "Hi", "media": ["http://insecure.example.invalid/a.jpg"]}, http=Http({})))

    def test_instagram_reel_waits_for_processing(self):
        states = iter([{"status_code": "IN_PROGRESS"}, {"status_code": "FINISHED"}])
        http = Http({("POST", f"{A.GRAPH}/77/media_publish"): (200, {"id": "R1"}, {}), ("POST", f"{A.GRAPH}/77/media"): (200, {"id": "C"}, {}),
                     ("GET", f"{A.GRAPH}/C"): lambda c: (200, next(states), {})})
        a = A.MetaInstagram()
        a.poll_wait = 0
        self.assertEqual(a.execute(self.ctx("meta-instagram", {"text": "Hi", "media": ["https://cdn.example.invalid/v.mp4"]}, http=http)), "R1")
        self.assertEqual(http.calls[0]["form"]["media_type"], "REELS")

    def test_tiktok_ai_flag_and_private_by_default(self):
        http = Http({("POST", "https://open.tiktokapis.com/v2/post/publish/creator_info/query/"): (200, {"data": {"privacy_level_options": ["SELF_ONLY", "PUBLIC_TO_EVERYONE"]}}, {}),
                     ("POST", "https://open.tiktokapis.com/v2/post/publish/video/init/"): (200, {"data": {"publish_id": "P1"}}, {})})
        self.assertEqual(A.ADAPTERS["tiktok"].execute(self.ctx("tiktok", {"text": "Hi", "media": ["https://cdn.example.invalid/v.mp4"]}, http=http)), "P1")
        info = http.calls[1]["json"]["post_info"]
        self.assertTrue(info["is_aigc"])
        self.assertEqual(info["privacy_level"], "SELF_ONLY")
        self.assertEqual(http.calls[1]["headers"]["Authorization"], "Bearer " + TOKEN)

    def test_youtube_resumable_upload_with_synthetic_media_flag(self):
        http = Http({("GET", "https://cdn.example.invalid/v.mp4"): (200, b"\x00\x01video", {}),
                     ("POST", "https://oauth2.googleapis.com/token"): (200, {"access_token": "AT"}, {}),
                     ("POST", "https://www.googleapis.com/upload/youtube/v3/videos"): (200, {}, {"Location": "https://upload.example.invalid/s1"}),
                     ("PUT", "https://upload.example.invalid/s1"): (200, {"id": "VID1"}, {})})
        ctx = self.ctx("youtube", {"title": "T", "text": "D", "media": ["https://cdn.example.invalid/v.mp4"]}, token={"refresh_token": "r"}, http=http,
                       env={"GOOGLE_CLIENT_ID": "g", "GOOGLE_CLIENT_SECRET": "s"}, action="upload")
        self.assertEqual(A.ADAPTERS["youtube"].execute(ctx), "VID1")
        meta = http.calls[2]["json"]
        self.assertTrue(meta["status"]["containsSyntheticMedia"])
        self.assertEqual(meta["status"]["privacyStatus"], "private")
        self.assertEqual(http.calls[3]["data"], b"\x00\x01video")

    def test_x_text_only_and_refresh(self):
        http = Http({("POST", "https://api.x.com/2/oauth2/token"): (200, {"access_token": "NEW", "refresh_token": "r2"}, {}),
                     ("POST", "https://api.x.com/2/tweets"): (201, {"data": {"id": "T1"}}, {})})
        ctx = self.ctx("x-twitter", {"text": "Hi"}, token={"access_token": TOKEN, "refresh_token": "r1"}, http=http, env={"X_CLIENT_ID": "x", "X_CLIENT_SECRET": "s"})
        self.assertEqual(A.ADAPTERS["x-twitter"].execute(ctx), "T1")
        self.assertEqual(http.calls[1]["headers"]["Authorization"], "Bearer NEW")
        ctx.save_token.assert_called_once_with({"access_token": "NEW", "refresh_token": "r2"})
        with self.assertRaises(A.HandError):
            A.ADAPTERS["x-twitter"].execute(self.ctx("x-twitter", {"text": "Hi", "media": ["https://cdn.example.invalid/a.jpg"]}, http=Http({})))

    def test_linkedin_post_and_version_header(self):
        http = Http({("POST", "https://api.linkedin.com/rest/posts"): (201, b"", {"x-restli-id": "urn:li:share:1"})})
        ctx = self.ctx("linkedin", {"text": "Hi"}, account={"id": "a", "handle": "h", "external_id": "person:abc"}, http=http)
        self.assertEqual(A.ADAPTERS["linkedin"].execute(ctx), "urn:li:share:1")
        self.assertEqual(http.calls[0]["json"]["author"], "urn:li:person:abc")
        self.assertRegex(http.calls[0]["headers"]["LinkedIn-Version"], r"^\d{6}$")
        self.assertEqual(A.linkedin_version(date(2026, 11, 18)), "202609")

    def test_netlify_deploy(self):
        http = Http({("GET", "https://files.example.invalid/site.zip"): (200, b"PK\x03\x04zip", {}),
                     ("POST", "https://api.netlify.com/api/v1/sites/site-1/deploys"): (200, {"id": "D1"}, {})})
        ctx = self.ctx("netlify", {"zip_url": "https://files.example.invalid/site.zip"}, account={"id": "a", "handle": "site-1", "external_id": "site-1"},
                       token={"api_key": "nfp"}, http=http, action="deploy")
        self.assertEqual(A.ADAPTERS["netlify"].execute(ctx), "D1")
        self.assertEqual(http.calls[1]["headers"]["Content-Type"], "application/zip")
        self.assertEqual(http.calls[1]["data"], b"PK\x03\x04zip")
        bad = Http({("GET", "https://files.example.invalid/site.zip"): (200, b"<html>", {})})
        with self.assertRaises(A.HandError):
            A.ADAPTERS["netlify"].execute(self.ctx("netlify", {"zip_url": "https://files.example.invalid/site.zip"}, token={"api_key": "k"}, http=bad, action="deploy"))

    def email_ctx(self, lead, suppressed=False):
        calls = []

        def rest(method, path, body=None):
            calls.append((method, path, body))
            if path.startswith("/rest/v1/leads"):
                return [lead] if lead else []
            if path.endswith("/rpc/is_suppressed"):
                return suppressed
            return None
        return self.ctx("email", {"lead_id": ACT, "subject": "Hello", "text": "Body"}, rpc=rest, http=Http({}), action="send"), calls

    def test_email_drafts_into_outbox_only(self):
        lead = {"id": ACT, "venture_id": "v1", "email": "lead@example.invalid", "do_not_contact": False, "consent_basis": "inquiry"}
        ctx, calls = self.email_ctx(lead)
        ref = A.ADAPTERS["email"].execute(ctx)
        self.assertEqual(ref, "outbox:hands-" + ACT)
        method, path, body = calls[-1]
        self.assertEqual((method, path), ("POST", "/rest/v1/outbox"))
        self.assertEqual((body["status"], body["needs_owner"], body["channel"]), ("draft", True, "email"))
        self.assertEqual(ctx.http.calls, [])          # no provider call: hq_mail sends only after the outbox approval and outreach_send_allowed

    def test_email_refusals(self):
        base = {"id": ACT, "venture_id": "v1", "email": "lead@example.invalid", "do_not_contact": False, "consent_basis": "inquiry"}
        for lead, sup, why in ((dict(base, do_not_contact=True), False, "do-not-contact"), (dict(base, consent_basis=None), False, "consent"),
                               (base, True, "suppressed"), (base, None, "suppressed"), (None, False, "not found")):
            ctx, calls = self.email_ctx(lead, sup)
            with self.assertRaises(A.HandError) as e:
                A.ADAPTERS["email"].execute(ctx)
            self.assertIn(why, str(e.exception))
            self.assertFalse(any(p == "/rest/v1/outbox" for _, p, _ in calls))
        ctx = self.ctx("email", {"lead_id": "someone@example.invalid"}, rpc=lambda *a: None, http=Http({}), action="send")
        with self.assertRaises(A.HandError):
            A.ADAPTERS["email"].execute(ctx)

    def test_http_refuses_plain_http(self):
        with self.assertRaises(A.HandError):
            A.http("GET", "http://example.invalid/")


# ------------------------------------------------------------------------------------------------------------------- Telegram
class Msg:
    def __init__(self, uid):
        self.chat = mock.Mock(id=uid)
        self.sent = []
        self.deleted = False

    async def reply_text(self, text, **kw):
        self.sent.append(text)

    async def delete(self):
        self.deleted = True


def upd(uid):
    m = Msg(uid)
    return mock.Mock(effective_user=mock.Mock(id=uid), effective_chat=mock.Mock(id=uid), message=m), m


class TelegramTests(unittest.TestCase):
    def setUp(self):
        p = mock.patch.dict(os.environ, {"JARVIS_OWNER_ID": "100"})
        p.start()
        self.addCleanup(p.stop)

    def run_cmd(self, fn, uid, args):
        u, m = upd(uid)
        asyncio.run(fn(u, mock.Mock(args=args, bot=mock.Mock())))
        return m

    def test_commands_owner_only(self):
        for _, fn in H.COMMANDS:
            m = self.run_cmd(fn, 999, ["x"])
            self.assertEqual(m.sent, [])
        self.assertEqual([n for n, _ in H.COMMANDS], ["accounts", "connect", "queue", "approve", "post"])

    def test_queue_and_accounts_say_sir(self):
        with mock.patch.object(H, "queue_text", return_value="Sir, the queue is empty."), mock.patch.object(H, "accounts_text", return_value="Sir, no accounts yet."):
            self.assertTrue(self.run_cmd(H.queue_cmd, 100, []).sent[0].startswith("Sir"))
            self.assertTrue(self.run_cmd(H.accounts_cmd, 100, []).sent[0].startswith("Sir"))

    def test_approve_and_post_resolve_ids(self):
        with mock.patch.object(H, "_resolve", return_value=ACT), mock.patch.object(H, "decide", return_value="Approved.") as d:
            m = self.run_cmd(H.approve_cmd, 100, ["11111111", "no"])
        d.assert_called_once_with(ACT, False, "owner:telegram:/approve")
        self.assertTrue(m.sent[0].startswith("Sir"))
        with mock.patch.object(H, "_resolve", return_value=ACT), mock.patch.object(H, "_rpc", return_value={"ok": True, "status": "dry_run"}) as r:
            m = self.run_cmd(H.post_cmd, 100, ["11111111"])
        r.assert_called_once_with("hands_run_now", {"p_id": ACT, "p_by": "owner:telegram:/post"})
        self.assertIn("Dry-run", m.sent[0])

    def test_connect_api_key_message_deleted(self):
        with mock.patch.object(H, "connect_key", return_value="Connected netlify @s. The key is in the vault only.") as c:
            m = self.run_cmd(H.connect_cmd, 100, ["netlify", "donna", "s", "nfp_key"])
        self.assertTrue(m.deleted)
        c.assert_called_once()
        self.assertNotIn("nfp_key", " ".join(m.sent))

    def test_queue_text_formats(self):
        rows = [{"id": ACT, "connector": "tiktok", "action": "post", "status": "dry_run", "scheduled_at": None, "payload": {"text": "Hello"}, "result": "dry run: would post"}]
        t = H.queue_text(get=lambda p: rows)
        self.assertIn("11111111 tiktok post dry_run: Hello", t)
        self.assertTrue(t.startswith("Sir"))


if __name__ == "__main__":
    unittest.main()
