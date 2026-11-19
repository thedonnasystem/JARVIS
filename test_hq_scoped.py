"""Scoped identities in hq.py (FENDEZY GROUP Phase 1, M1): which credential a request carries. No network: urlopen is replaced and the headers are inspected."""
import base64
import json
import os
import time
import unittest
import urllib.error
from unittest import mock

import hq

SERVICE = "service-key-for-tests"


def jwt(claims: dict) -> str:
    enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")
    return f"{enc({'alg': 'HS256', 'typ': 'JWT'})}.{enc(claims)}.c2lnbmF0dXJl"


def tok(identity="jarvis", role="fz_jarvis", **extra):
    c = {"role": role, "identity": identity, "iat": int(time.time()), "exp": int(time.time()) + 3600}
    c.update(extra)
    return jwt(c)


class _Resp:
    def __init__(self, body=b'{"ok": true}'):
        self.body = body

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class ScopedTests(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict(os.environ, {}, clear=False)
        self.env.start()
        for k in (hq.SCOPED_TOKENS_ENV, hq.SCOPED_GATEWAY_ENV):
            os.environ.pop(k, None)
        self.p = [mock.patch.object(hq, "HQ_SUPABASE_URL", "https://example.invalid"), mock.patch.object(hq, "HQ_SUPABASE_SERVICE_KEY", SERVICE)]
        for p in self.p:
            p.start()
        hq._scoped_warned.clear()
        self.sent = []

        def fake_urlopen(req, timeout=30):
            self.sent.append({k.lower(): v for k, v in req.header_items()})
            return _Resp()
        self.u = mock.patch("urllib.request.urlopen", side_effect=fake_urlopen)
        self.u.start()

    def tearDown(self):
        self.u.stop()
        for p in self.p:
            p.stop()
        self.env.stop()

    def install(self, **tokens):
        os.environ[hq.SCOPED_TOKENS_ENV] = json.dumps(tokens)

    def bearer(self, i=-1):
        return self.sent[i]["authorization"].split(" ", 1)[1]

    # --- fallback: nothing configured means exactly today's behaviour
    def test_no_tokens_keeps_service_key(self):
        hq._request("GET", "/rest/v1/agents", identity="jarvis")
        self.assertEqual(self.bearer(), SERVICE)
        self.assertEqual(self.sent[-1]["apikey"], SERVICE)

    def test_plain_request_unchanged(self):
        self.install(jarvis=tok())
        hq._request("GET", "/rest/v1/agents")
        self.assertEqual(self.bearer(), SERVICE)

    # --- configured: the scoped token is used, only inside the scope
    def test_valid_token_used_and_reset(self):
        t = tok()
        self.install(jarvis=t)
        with hq.as_identity("jarvis") as s:
            self.assertTrue(s.scoped)
            hq._request("GET", "/rest/v1/tasks")
        self.assertEqual(self.bearer(), t)
        self.assertEqual(self.sent[-1]["apikey"], t)          # no gateway key: a plain PostgREST
        hq._request("GET", "/rest/v1/tasks")
        self.assertEqual(self.bearer(), SERVICE)                # back to the service key after the scope
        self.assertIsNone(hq.AUTH_OVERRIDE.get())

    def test_identity_kwarg(self):
        t = tok("office:donna:manager", "fz_office_agent")
        self.install(**{"office:donna:manager": t})
        hq._request("GET", "/rest/v1/tasks", identity="office:donna:manager")
        self.assertEqual(self.bearer(), t)

    def test_gateway_key_goes_in_apikey(self):
        t = tok()
        self.install(jarvis=t)
        os.environ[hq.SCOPED_GATEWAY_ENV] = jwt({"role": "anon"})
        hq._request("GET", "/rest/v1/tasks", identity="jarvis")
        self.assertEqual(self.bearer(), t)
        self.assertEqual(self.sent[-1]["apikey"], os.environ[hq.SCOPED_GATEWAY_ENV])

    def test_gateway_refuses_privileged_keys(self):
        self.install(jarvis=tok())
        for bad in (SERVICE, "sb_secret_abc", jwt({"role": "service_role"})):
            os.environ[hq.SCOPED_GATEWAY_ENV] = bad
            with self.assertRaises(hq.ScopedTokenError):
                hq._request("GET", "/rest/v1/tasks", identity="jarvis")
        self.assertEqual(self.sent, [])                         # nothing was sent
        self.assertIsNone(hq.AUTH_OVERRIDE.get())

    # --- tokens that must never be used (fall back, or refuse with require=True)
    def test_unusable_tokens(self):
        cases = {
            "wrongrole": tok(role="service_role"),
            "wrongidentity": tok(identity="auditor", role="fz_auditor"),
            "hassub": tok(sub="99999999-9999-9999-9999-999999999999"),
            "expired": tok(exp=int(time.time()) - 5),
            "malformed": "not-a-jwt",
            "servicekey": SERVICE,
        }
        for state, t in cases.items():
            with self.subTest(state=state):
                self.install(jarvis=t)
                self.assertEqual(hq.scoped_token_state("jarvis")[0], state)
                hq._request("GET", "/rest/v1/tasks", identity="jarvis")
                self.assertEqual(self.bearer(), SERVICE)        # default: today's behaviour
                with self.assertRaises(hq.ScopedTokenError):
                    with hq.as_identity("jarvis", require=True):
                        pass
        for role in ("backup_reader", "anon", "authenticated"):
            self.install(jarvis=tok(role=role))
            self.assertEqual(hq.scoped_token_state("jarvis")[0], "wrongrole")

    def test_bad_json_is_off(self):
        os.environ[hq.SCOPED_TOKENS_ENV] = "{not json"
        self.assertEqual(hq.scoped_token_state("jarvis")[0], "unset")
        hq._request("GET", "/rest/v1/tasks", identity="jarvis")
        self.assertEqual(self.bearer(), SERVICE)

    def test_backup_override_is_never_replaced(self):
        self.install(jarvis=tok())
        r = hq.AUTH_OVERRIDE.set("backup-reader-token")
        try:
            hq._request("POST", "/rest/v1/rpc/x", {}, identity="jarvis")
            self.assertEqual(self.bearer(), "backup-reader-token")
            with self.assertRaises(hq.ScopedTokenError):
                with hq.as_identity("jarvis", require=True):
                    pass
        finally:
            hq.AUTH_OVERRIDE.reset(r)

    def test_refusal_is_not_retried_with_the_service_key(self):
        t = tok()
        self.install(jarvis=t)
        calls = []

        def refuse(req, timeout=30):
            calls.append(dict(req.header_items())["Authorization"])
            raise urllib.error.HTTPError(req.full_url, 403, "permission denied", {}, None)
        with mock.patch("urllib.request.urlopen", side_effect=refuse):
            with self.assertRaises(urllib.error.HTTPError):
                hq._request("GET", "/rest/v1/approval_requests", identity="jarvis")
        self.assertEqual(calls, [f"Bearer {t}"])               # one call, scoped, no second try with the service key

    def test_scoped_check(self):
        self.assertEqual(hq.scoped_check("jarvis")["reason"], "token unset")
        t = tok()
        self.install(jarvis=t)
        with mock.patch("urllib.request.urlopen", return_value=_Resp(b'{"ok": true, "identity": "jarvis", "scope": "group"}')) as u:
            r = hq.scoped_check("jarvis")
        self.assertTrue(r["ok"])
        self.assertEqual(dict(u.call_args[0][0].header_items())["Authorization"], f"Bearer {t}")
        self.assertTrue(u.call_args[0][0].full_url.endswith("/rest/v1/rpc/fz_whoami"))


@unittest.skipUnless(os.environ.get("FZ_DB_TESTS") and os.environ.get("REPLICA_URL"), "needs FZ_DB_TESTS=1 and a replica database (scripts/replica/run.sh runs it)")
class DbTests(unittest.TestCase):
    """The REAL hq._request path against the replica's REAL RLS (scripts/replica/pg_adapter.py plays PostgREST: role + claims from the token). One transaction, rolled back."""

    def setUp(self):
        import sys
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts", "replica"))
        from pg_adapter import PgAdapter
        self.db = PgAdapter(os.environ["REPLICA_URL"])
        self.db.conn.autocommit = False
        self.addCleanup(self.db.conn.close)
        self.addCleanup(self.db.conn.rollback)
        for p in (mock.patch.dict(os.environ, {}, clear=False), mock.patch.object(hq, "_request", self.db), mock.patch.object(hq, "HQ_SUPABASE_SERVICE_KEY", SERVICE)):
            p.start()
            self.addCleanup(p.stop)
        os.environ.pop(hq.SCOPED_GATEWAY_ENV, None)
        self.A, self.B = "office:b2b-records:manager", "office:donna:manager"
        self.db.sql("update public.fz_offices set status = 'active' where slug in ('b2b-records', 'donna')")
        self.db.sql("update public.fz_identities set status = 'active' where slug in (%s, %s)", (self.A, self.B))
        self.db.sql("insert into public.tasks (title, office_id) values ('py A', 'f0000000-0000-4000-8000-000000000001'), ('py B', 'f0000000-0000-4000-8000-000000000002')")
        os.environ[hq.SCOPED_TOKENS_ENV] = json.dumps({self.A: tok(self.A, "fz_office_agent"), self.B: tok(self.B, "fz_office_agent"), "jarvis": tok()})

    def titles(self, identity=None):
        rows = hq._request("GET", "/rest/v1/tasks?title=like.py*&select=title&order=title.asc", identity=identity) or []
        return [r["title"] for r in rows]

    def test_offices_are_isolated(self):
        self.assertEqual(self.titles(self.A), ["py A"])
        self.assertEqual(self.titles(self.B), ["py B"])
        self.assertEqual(self.titles("jarvis"), ["py A", "py B"])     # group scope
        self.assertEqual(self.titles(), ["py A", "py B"])              # no identity: the service path, unchanged

    def test_fallback_without_token(self):
        os.environ[hq.SCOPED_TOKENS_ENV] = "{}"
        self.assertEqual(self.titles(self.A), ["py A", "py B"])       # not installed yet: today's behaviour (service path)

    def test_write_is_stamped_and_scoped(self):
        rows = hq._request("POST", "/rest/v1/tasks", {"title": "py new", "office_id": "f0000000-0000-4000-8000-000000000002"}, prefer="return=representation", identity=self.A)
        self.assertEqual((rows[0]["office_id"], rows[0]["created_by"]), ("f0000000-0000-4000-8000-000000000001", self.A))
        with self.assertRaises(urllib.error.HTTPError):
            hq._request("POST", "/rest/v1/approval_requests", {"actor": "jarvis", "action": "take_loan", "recommendation": "x", "status": "approved"}, identity="jarvis")

    def test_whoami_and_gate(self):
        r = hq.scoped_check(self.A)
        self.assertTrue(r["ok"], r)
        self.assertEqual((r["office"], r["scope"]), ("b2b-records", "office"))
        d = hq._request("POST", "/rest/v1/rpc/fz_authorize_action", {"p_action": "research", "p_actor": "owner"}, identity=self.A)
        self.assertEqual(d["decision"], "allow")
        self.assertEqual(self.db.sql("select actor from public.action_log order by id desc limit 1")[0]["actor"], self.A)


if __name__ == "__main__":
    unittest.main()
