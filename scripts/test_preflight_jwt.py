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

    def test_a_valid_reader_token_passes_that_check(self):
        rc, line, _ = run(jwt(role="backup_reader", exp=int(time.time()) + 3600))
        self.assertTrue(line.startswith("PASS"), line)


if __name__ == "__main__":
    unittest.main()
