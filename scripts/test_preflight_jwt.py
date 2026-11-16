"""Preflight BACKUP_READER_JWT checks (D4): unset / garbage / wrong role / expired / no exp fail under --require-pii-exclusion; only role=backup_reader with a future exp passes. No network, no database."""
import base64, json, os, subprocess, time, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRE = os.path.join(ROOT, "ops", "backup_activation_preflight.sh")


def b64(o):
    return base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b"=").decode()


def jwt(**claims):
    return f"{b64({'alg': 'HS256', 'typ': 'JWT'})}.{b64(claims)}.c2ln"


def run(token=None, *args):
    env = {"PATH": os.environ["PATH"], "BACKUP_KEY": "x" * 43 + "=", "BACKUP_PUT_URL": "https://store.example.com/b/{name}", "BACKUP_AUTH": "k:s"}
    if token is not None:
        env["BACKUP_READER_JWT"] = token
    p = subprocess.run(["bash", PRE, "--require-pii-exclusion", *args], env=env, capture_output=True, text=True, timeout=120)
    line = next((l for l in p.stdout.splitlines() if "BACKUP_READER_JWT" in l and not l.startswith("PASS  BACKUP_READER_JWT is set (length")), "")
    return p.returncode, line, p.stdout


class PreflightJwt(unittest.TestCase):
    def test_unset_is_a_fail_and_exits_nonzero(self):
        rc, line, _ = run(None)
        self.assertTrue(line.startswith("FAIL"), line); self.assertNotEqual(rc, 0)

    def test_garbage_and_wrong_role_and_expired_and_no_exp_all_fail(self):
        future = int(time.time()) + 3600
        for name, tok in (("garbage", "abc"), ("not json", "a.b.c"), ("service_role", jwt(role="service_role", exp=future)), ("authenticated", jwt(role="authenticated", exp=future)),
                          ("expired", jwt(role="backup_reader", exp=int(time.time()) - 5)), ("no exp", jwt(role="backup_reader")), ("exp not a number", jwt(role="backup_reader", exp="9999999999")),
                          ("role in list", jwt(role=["backup_reader"], exp=future))):
            with self.subTest(name):
                rc, line, out = run(tok)
                self.assertTrue(line.startswith("FAIL"), (name, line)); self.assertNotEqual(rc, 0, name)
                self.assertFalse(any(l.startswith("PASS") and "backup_reader" in l and "JWT" in l for l in out.splitlines()), name)
                self.assertNotIn(tok, out)                                   # the token is never printed

    def test_non_finite_exp_future_nbf_and_duplicate_claims_fail(self):
        """Round 8 (N1). Expected FAIL for each; actual before the fix: PASS (NaN / Infinity / 1e400 compared as 'not expired', nbf ignored, the last duplicate `role` won)."""
        future = int(time.time()) + 3600
        raw = lambda payload: f"{b64({'alg': 'HS256'})}.{base64.urlsafe_b64encode(payload.encode()).rstrip(b'=').decode()}.c2ln"
        for name, tok in (("exp NaN", raw('{"role": "backup_reader", "exp": NaN}')), ("exp Infinity", raw('{"role": "backup_reader", "exp": Infinity}')), ("exp 1e400", raw('{"role": "backup_reader", "exp": 1e400}')),
                          ("nbf in the future", jwt(role="backup_reader", exp=future, nbf=future)), ("nbf not a number", jwt(role="backup_reader", exp=future, nbf="later")),
                          ("duplicate role, reader last", raw('{"role": "service_role", "role": "backup_reader", "exp": %d}' % future)),
                          ("duplicate role, reader first", raw('{"role": "backup_reader", "role": "service_role", "exp": %d}' % future))):
            with self.subTest(name):
                rc, line, out = run(tok)
                self.assertTrue(line.startswith("FAIL"), (name, line)); self.assertNotEqual(rc, 0, name)
                self.assertNotIn(tok, out)

    def test_nbf_in_the_past_is_accepted(self):
        rc, line, _ = run(jwt(role="backup_reader", exp=int(time.time()) + 3600, nbf=int(time.time()) - 30))
        self.assertTrue(line.startswith("PASS"), line)

    def test_gateway_key_is_checked_without_being_printed(self):
        """Round 8 (S6). Expected: unset = WARN, anon / publishable = PASS, service / secret / non-anon token = FAIL; the value never appears in the output."""
        tok = jwt(role="backup_reader", exp=int(time.time()) + 3600)
        for gw, want in ((None, "WARN"), ("sb_publishable_abc123", "PASS"), (jwt(role="anon", exp=4102444800), "PASS"), ("sb_secret_abc123", "FAIL"), (jwt(role="service_role", exp=4102444800), "FAIL")):
            with self.subTest(want=want, gw=(gw or "")[:14]):
                env = {"PATH": os.environ["PATH"], "BACKUP_KEY": "x" * 43 + "=", "BACKUP_PUT_URL": "https://store.example.com/b/{name}", "BACKUP_AUTH": "k:s", "BACKUP_READER_JWT": tok}
                if gw:
                    env["BACKUP_GATEWAY_APIKEY"] = gw
                out = subprocess.run(["bash", PRE], env=env, capture_output=True, text=True, timeout=120).stdout
                line = next(l for l in out.splitlines() if "BACKUP_GATEWAY_APIKEY" in l)
                self.assertTrue(line.startswith(want), line)
                if gw:
                    self.assertNotIn(gw, out)

    def test_service_key_reused_as_gateway_key_fails(self):
        env = {"PATH": os.environ["PATH"], "BACKUP_KEY": "x" * 43 + "=", "BACKUP_PUT_URL": "https://store.example.com/b/{name}", "BACKUP_AUTH": "k:s",
               "BACKUP_READER_JWT": jwt(role="backup_reader", exp=int(time.time()) + 3600), "HQ_SUPABASE_SERVICE_KEY": "opaque-service-key", "BACKUP_GATEWAY_APIKEY": "opaque-service-key"}
        out = subprocess.run(["bash", PRE], env=env, capture_output=True, text=True, timeout=120).stdout
        self.assertTrue(next(l for l in out.splitlines() if "BACKUP_GATEWAY_APIKEY" in l).startswith("FAIL")); self.assertNotIn("opaque-service-key", out)

    def test_without_a_database_the_event_trigger_check_says_it_could_not_run(self):
        """Round 8 (S4): the event-trigger line exists even when nothing can be checked, and is a FAIL under --require-pii-exclusion (never a silent pass)."""
        rc, _, out = run(jwt(role="backup_reader", exp=int(time.time()) + 3600))
        line = next(l for l in out.splitlines() if "event trigger ffm_backup_acl_sweep" in l)
        self.assertTrue(line.startswith("FAIL"), line); self.assertNotEqual(rc, 0)

    def test_a_valid_reader_token_passes_that_check(self):
        rc, line, _ = run(jwt(role="backup_reader", exp=int(time.time()) + 3600))
        self.assertTrue(line.startswith("PASS"), line)


if __name__ == "__main__":
    unittest.main()
