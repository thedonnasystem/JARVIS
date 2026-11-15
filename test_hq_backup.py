import re
import io, json, logging, os, sys, tarfile, unittest, urllib.error
from datetime import datetime, timezone
from unittest import mock

from cryptography.fernet import Fernet

import hq_backup as B
B._NO_SLEEP = True

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "scripts", "replica"))
from fake_b2 import FakeB2  # noqa: E402

KEY = Fernet.generate_key().decode()
ENV = {"BACKUP_KEY": KEY, "BACKUP_PUT_URL": "https://store.example.com/b/{name}"}
SCHEMA = {"server_version": "17.0", "tables": [{"name": "ideas"}, {"name": "ledger"}, {"name": "push_config"}, {"name": "tasks"}],
          "constraints": [{"table": "tasks", "type": "p", "def": "PRIMARY KEY (id)"}, {"table": "ledger", "type": "p", "def": "PRIMARY KEY (day, kind)"}],
          "functions": [{"sig": "f()", "def": "create function f()"}], "indexes": [], "triggers": []}
# the fake rows use made-up columns (v, note): treat the made-up ones as KEEP, the real spec columns stay as they are
B.KEEP_COLUMNS = B.KEEP_COLUMNS | {("ideas", "v"), ("ideas", "note"), ("tasks", "v"), ("ledger", "v")}
ROWS = {"ideas": 3, "ledger": 3, "tasks": 2, "push_config": 1}


REDACTION = {"version": 2, "known_client_terms": 4, "spec": [{"table_name": t, "column_name": c, "kind": "text", "mode": "strict", "max_len": 500}
                                                              for t, c in (("audit_log", "detail"), ("ledger", "note"), ("tasks", "result"), ("agent_runs", "summary"))]}
POLICY = {"exported": ["ideas", "ledger", "tasks"], "excluded": [{"table": "leads", "class": "client_pii", "reason": "client personal data"}, {"table": "push_config", "class": "secret", "reason": "keys"}], "unclassified": []}


def fake_request(method, path, body=None, prefer=None, timeout=30, exact=False):
    if method == "POST" and path.endswith("/rpc/backup_export_policy"):
        return POLICY
    if method == "POST" and path.endswith("/rpc/backup_schema"):
        return SCHEMA
    if method == "GET" and "/audit_log" in path:
        return []
    if method == "GET":
        t = path.split("/rest/v1/")[1].split("?")[0]
        m = re.search(r"offset=(\d+)", path); off = int(m.group(1)) if m else 0
        return [{"id": i, "v": f"{t}{i}", "note": "café \U0001F600"} for i in range(off, ROWS.get(t, 0))]
    return None


def no_schema_request(method, path, body=None, prefer=None, timeout=30, exact=False):
    if path.endswith("/rpc/backup_schema"):
        raise urllib.error.HTTPError(path, 404, "no function", {}, None)
    return fake_request(method, path, body, prefer)


class FakeStore:
    """Captures what the run() path writes to hq_request (audit rows and owner messages)."""
    def __init__(self):
        self.posts = []

    def __call__(self, method, path, body=None, prefer=None, timeout=30, exact=False):
        if method == "POST" and not path.endswith(("/rpc/backup_schema", "/rpc/backup_export_policy")):
            self.posts.append((path, body))
            return None
        return fake_request(method, path, body, prefer)


def b2_env(fake, auth="keyW:secretW"):
    return {"BACKUP_KEY": KEY, "BACKUP_PUT_URL": f"b2://{fake.bucket_id}/hq", "BACKUP_AUTH": auth}


def b2_patches(fake):
    return [mock.patch.object(B, "B2_AUTH_URL", fake.auth_url),
            mock.patch.object(B, "_b2_ok_url", lambda u: u.startswith(fake.url))]


class Dump(unittest.TestCase):
    def test_off_without_config(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(B.run()["reason"], "not configured")

    def test_dump_has_manifest_schema_and_skips_secret_tables(self):
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=fake_request):
            blob, m = B.dump()
        self.assertEqual(m["format"], 2)
        self.assertTrue(m["complete"]); self.assertEqual(m["table_list_source"], "database export policy")
        self.assertNotIn("push_config", m["tables"])          # private keys never leave the database
        self.assertEqual(m["tables"]["ideas"]["rows"], 3); self.assertEqual(m["total_rows"], 8)
        self.assertEqual(m["schema"]["counts"]["functions"], 1)
        names = tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz").getnames()
        self.assertIn("manifest.json", names); self.assertIn("schema.json", names); self.assertIn("data/ideas.jsonl", names)
        self.assertNotIn("data/push_config.jsonl", names)

    def test_without_schema_function_backup_is_flagged_incomplete(self):
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=no_schema_request):
            blob, m = B.dump()
        self.assertFalse(m["complete"]); self.assertEqual(m["table_list_source"], "database export policy")
        self.assertEqual(sorted(m["tables"]), ["ideas", "ledger", "tasks"])                 # only what the policy allows; no built-in list to fall back on
        self.assertNotIn("push_config", m["tables"]); self.assertNotIn("push_subscriptions", m["tables"])

    def test_unicode_survives(self):
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=fake_request):
            blob, _ = B.dump()
        raw = tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz").extractfile("data/ideas.jsonl").read().decode()
        self.assertIn("café \U0001F600", json.loads(raw.split("\n")[0])["note"])

    def test_decimals_are_written_exactly_not_through_float(self):
        from decimal import Decimal
        line = B.row_json({"a": Decimal("30.00"), "b": Decimal("0.1234567890123456789012"), "c": 5, "d": "x", "e": None, "f": Decimal("-1.5E+3"),
                           "g": {"n": [Decimal("2.50")]}, "h": Decimal("NaN"), "t": "\\u0000DEC:1"})
        self.assertIn('"a":30.00', line); self.assertIn('"b":0.1234567890123456789012', line); self.assertIn('"c":5', line)
        self.assertIn('"f":-1.5E+3', line); self.assertIn('[2.50]', line)
        back = json.loads(line, parse_float=Decimal)
        self.assertEqual(str(back["a"]), "30.00"); self.assertEqual(str(back["b"]), "0.1234567890123456789012")
        self.assertEqual(back["h"], "NaN"); self.assertEqual(back["t"], "\\u0000DEC:1")        # look-alike text is left alone

    def test_backup_reads_with_exact_decimals(self):
        seen = []
        def req(method, path, body=None, prefer=None, timeout=30, exact=False):
            if "/rest/v1/ideas" in path:
                seen.append(exact)
            return fake_request(method, path, body, prefer)
        with mock.patch("hq._request", side_effect=req):
            B.dump()
        self.assertTrue(seen and all(seen))   # every read asked for exact numbers

    def test_primary_key_order_parsed_from_schema(self):
        self.assertEqual(B._pk_order(SCHEMA, "ledger"), "&order=day.asc,kind.asc")
        self.assertEqual(B._pk_order(SCHEMA, "tasks"), "&order=id.asc")
        self.assertEqual(B._pk_order(None, "agents"), "&order=slug.asc")
        evil = {"constraints": [{"table": "t", "type": "p", "def": 'PRIMARY KEY ("a;drop")'}]}
        self.assertEqual(B._pk_order(evil, "t"), "&order=id.asc")

    def test_paging_reads_every_page(self):
        calls = []
        def req(method, path, body=None, prefer=None, timeout=30, exact=False):
            if path.endswith("/rpc/backup_export_policy"):
                return {"exported": ["big"], "excluded": [], "unclassified": []}
            if path.endswith("/rpc/backup_schema"):
                return {"tables": [{"name": "big"}], "constraints": []}
            off = int(path.split("offset=")[1]); calls.append(off)
            return [{"id": i} for i in range(off, min(off + B.PAGE, 2300))]
        with mock.patch("hq._request", side_effect=req):
            _, m = B.dump()
        self.assertEqual(m["tables"]["big"]["rows"], 2300); self.assertEqual(calls, [0, 1000, 2000, 2300] * 2)   # two consistency passes, every page plus the empty terminating page

    def test_unordered_fallback_when_sort_column_missing(self):
        def req(method, path, body=None, prefer=None, timeout=30, exact=False):
            if "order=" in path:
                raise urllib.error.HTTPError(path, 400, "bad", {}, None)
            return fake_request(method, path)
        with mock.patch("hq._request", side_effect=req):
            _, m = B.dump()
        self.assertEqual(m["tables"]["ideas"]["rows"], 3)


class Consistency(unittest.TestCase):
    def _moving(self, stop_after=None):
        calls = {"n": 0}
        def req(method, path, body=None, prefer=None, timeout=30, exact=False):
            if method == "GET" and "/rest/v1/tasks" in path:
                if re.search(r"offset=[1-9]", path):
                    return []
                calls["n"] += 1
                v = calls["n"] if (stop_after is None or calls["n"] <= stop_after) else stop_after + 1
                return [{"id": 1, "v": f"changed-{v}"}]
            return fake_request(method, path, body, prefer)
        return req, calls

    def test_stable_data_is_consistent(self):
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=fake_request):
            _, m = B.dump()
        self.assertTrue(m["consistency"]["consistent"]); self.assertEqual(m["consistency"]["method"], "two identical full reads")
        self.assertEqual(m["consistency"]["attempts"], 1); self.assertIn("snapshot_unavailable", m["consistency"])

    def test_data_that_settles_is_retried_then_consistent(self):
        req, calls = self._moving(stop_after=2)
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=req):
            _, m = B.dump()
        self.assertTrue(m["consistency"]["consistent"])
        self.assertGreaterEqual(m["consistency"]["attempts"], 2)

    def test_data_that_keeps_moving_is_flagged_and_bounded(self):
        req, calls = self._moving()
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=req):
            _, m = B.dump()
        self.assertFalse(m["consistency"]["consistent"])
        self.assertEqual(m["consistency"]["changing_tables"], ["tasks"])
        self.assertEqual(calls["n"], 1 + B.CONSISTENCY_ATTEMPTS)   # bounded: no endless loop

    def test_inconsistent_backup_still_saved_and_owner_told(self):
        req, calls = self._moving()
        sent = []
        def wrapped(method, path, body=None, prefer=None, timeout=30, exact=False):
            if method == "POST" and path.endswith("/owner_messages"):
                sent.append(body["body"])
            return req(method, path, body, prefer)
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=wrapped), \
             mock.patch.object(B, "put_files", return_value={"target": "t", "files": {}}):
            r = B.run(force=True)
        self.assertTrue(r["ok"])
        self.assertTrue(any("out of step" in m for m in sent))


class Preflight(unittest.TestCase):
    def check(self, fake, env=None):
        ps = b2_patches(fake)
        with mock.patch.dict(os.environ, b2_env(fake) if env is None else env, clear=True), mock.patch("hq._request", side_effect=FakeStore()), ps[0], ps[1]:
            return B.preflight()

    def status(self, res, text):
        return next(r["status"] for r in res if text in r["check"])

    def test_good_write_key_passes_and_never_uploads(self):
        with FakeB2(keys={"keyW": ("secretW", {"writeFiles"})}) as fake:
            res = self.check(fake)
            self.assertFalse([r for r in res if r["status"] == "fail"], res)
            self.assertEqual(self.status(res, "no delete/read/admin"), "pass")
            self.assertEqual(fake.files, []); self.assertEqual(fake.upload_calls, 0)

    def test_key_with_read_and_delete_warns(self):
        with FakeB2(keys={"keyW": ("secretW", {"writeFiles", "deleteFiles", "readFiles"})}) as fake:
            res = self.check(fake)
            self.assertEqual(self.status(res, "no delete/read/admin"), "warn")

    def test_read_only_key_fails(self):
        with FakeB2() as fake:
            res = self.check(fake, {**b2_env(fake), "BACKUP_AUTH": "keyR:secretR"})
            self.assertEqual(self.status(res, "Key can write files"), "fail")

    def test_wrong_key_and_missing_vars_fail_without_leaking(self):
        with FakeB2() as fake:
            res = self.check(fake, {**b2_env(fake), "BACKUP_AUTH": "keyW:WRONGSECRET"})
            self.assertEqual(self.status(res, "accepts the application key"), "fail")
            self.assertNotIn("WRONGSECRET", repr(res))
            res = self.check(fake, {})
            self.assertEqual(self.status(res, "BACKUP_KEY is set"), "fail")
            self.assertEqual(self.status(res, "BACKUP_AUTH is set"), "fail")

    def test_bad_encryption_key_and_other_bucket(self):
        with FakeB2() as fake:
            res = self.check(fake, {**b2_env(fake), "BACKUP_KEY": "not-a-key"})
            self.assertEqual(self.status(res, "valid encryption key"), "fail")
            res = self.check(fake, {**b2_env(fake), "BACKUP_PUT_URL": "b2://0000000000000000aaaa/hq"})
            self.assertEqual(self.status(res, "limited to the backup bucket"), "fail")


class Snapshot(unittest.TestCase):
    """backup_snapshot(): every table + schema from ONE SQL statement (mutually consistent)."""
    TABLES = ["ideas", "ledger", "tasks"]

    def snap_req(self, data=None, fail=None, calls=None, redaction=None):
        from decimal import Decimal
        data = data if data is not None else {"ideas": [{"id": 2, "n": "b"}, {"id": 1, "n": "a"}], "ledger": [{"id": 1, "amt": Decimal("30.00")}], "tasks": []}
        def req(method, path, body=None, prefer=None, timeout=30, exact=False):
            if calls is not None:
                calls.append(path)
            if path.endswith("/rpc/backup_snapshot"):
                if fail:
                    raise fail
                return {"data": data, "schema": {**SCHEMA, "tables": [{"name": n} for n in self.TABLES + ["push_config"]], "sequences": [{"name": "s", "last_value": 7}]}, "method": "x", "policy": POLICY, "redaction": redaction if redaction is not None else REDACTION}
            return fake_request(method, path, body, prefer, exact=exact)
        return req

    def test_snapshot_is_used_once_with_no_table_reads(self):
        calls = []
        with mock.patch("hq._request", side_effect=self.snap_req(calls=calls)):
            blob, m = B.dump()
        self.assertEqual([c for c in calls if "/rest/v1/ideas" in c or "/rest/v1/backup_schema" in c or c.endswith("rpc/backup_schema")], [])
        self.assertTrue(m["consistency"]["consistent"]); self.assertIn("single SQL statement", m["consistency"]["method"])
        self.assertEqual(sorted(m["tables"]), self.TABLES); self.assertTrue(m["complete"])
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
            self.assertIn(b"30.00", tar.extractfile("data/ledger.jsonl").read())            # exact decimal scale survives
            lines = tar.extractfile("data/ideas.jsonl").read().decode().split("\n")
            self.assertEqual(len(lines), 2); self.assertEqual(lines, sorted(lines))          # deterministic order
            self.assertEqual(json.loads(tar.extractfile("schema.json").read())["sequences"][0]["last_value"], 7)

    def test_same_data_gives_same_file_hash(self):
        with mock.patch("hq._request", side_effect=self.snap_req()):
            _, m1 = B.dump()
        rev = {"ideas": [{"id": 1, "n": "a"}, {"id": 2, "n": "b"}], "ledger": [{"id": 1, "amt": __import__("decimal").Decimal("30.00")}], "tasks": []}
        with mock.patch("hq._request", side_effect=self.snap_req(data=rev)):
            _, m2 = B.dump()
        self.assertEqual({t: v["sha256"] for t, v in m1["tables"].items()}, {t: v["sha256"] for t, v in m2["tables"].items()})

    def test_snapshot_errors_fall_back_to_two_reads_with_a_reason(self):
        for err, text in ((urllib.error.HTTPError("u", 500, "x", {}, None), "HTTP 500"), (urllib.error.HTTPError("u", 404, "x", {}, None), "not installed"), (TimeoutError(), "TimeoutError")):
            with mock.patch("hq._request", side_effect=self.snap_req(fail=err)):
                _, m = B.dump()
            self.assertIn(text, m["consistency"]["snapshot_unavailable"]); self.assertEqual(m["consistency"]["method"], "two identical full reads")

    def test_inconsistent_snapshot_content_is_rejected_not_trusted(self):
        bad = {"ideas": [], "ledger": []}                                    # missing "tasks"
        with mock.patch("hq._request", side_effect=self.snap_req(data=bad)):
            _, m = B.dump()
        self.assertIn("does not match", m["consistency"]["snapshot_unavailable"])
        leaked = {"ideas": [], "ledger": [], "tasks": [], "push_config": [{"vapid_private": "SECRET"}]}
        with mock.patch("hq._request", side_effect=self.snap_req(data=leaked)):
            blob, m = B.dump()
        self.assertNotIn("push_config", m["tables"])
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
            self.assertFalse([n for n in tar.getnames() if "push" in n])


class ReviewFixes(unittest.TestCase):
    """Regressions for defects found by the independent review."""

    def test_real_backblaze_hosts_pass_and_others_fail(self):
        for u in ("https://api003.backblazeb2.com", "https://pod-000-1143-05.backblaze.com/b2api/v4/b2_upload_file/abc/def",
                  "https://f003.backblazeb2.com/file"):
            self.assertTrue(B._b2_ok_url(u), u)
        for u in ("http://pod-000-1.backblaze.com/x", "https://evilbackblaze.com/x", "https://backblaze.com.evil.io/x", "https://127.0.0.1/x", "ftp://a.backblazeb2.com"):
            self.assertFalse(B._b2_ok_url(u), u)

    def test_schema_error_other_than_404_fails_the_backup_instead_of_downgrading(self):
        def req(method, path, body=None, prefer=None, timeout=30, exact=False):
            if path.endswith("/rpc/backup_schema"):
                raise urllib.error.HTTPError(path, 500, "boom", {}, None)
            return fake_request(method, path, body, prefer)
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=req):
            with self.assertRaises(urllib.error.HTTPError):
                B.dump()
            r = B.run(force=True)
        self.assertFalse(r["ok"])

    def test_row_cap_below_page_size_loses_nothing(self):
        def req(method, path, body=None, prefer=None, timeout=30, exact=False):
            if path.endswith("/rpc/backup_export_policy"):
                return {"exported": ["big"], "excluded": [], "unclassified": []}
            if path.endswith("/rpc/backup_schema"):
                return {"tables": [{"name": "big"}], "constraints": []}
            off = int(path.split("offset=")[1]); return [{"id": i} for i in range(off, min(off + 100, 450))]   # server caps every page at 100
        with mock.patch("hq._request", side_effect=req):
            _, m = B.dump()
        self.assertEqual(m["tables"]["big"]["rows"], 450)

    def test_unordered_fallback_refuses_large_tables(self):
        def req(method, path, body=None, prefer=None, timeout=30, exact=False):
            if path.endswith("/rpc/backup_export_policy"):
                return {"exported": ["big"], "excluded": [], "unclassified": []}
            if path.endswith("/rpc/backup_schema"):
                return {"tables": [{"name": "big"}], "constraints": []}
            if "order=" in path:
                raise urllib.error.HTTPError(path, 400, "no column", {}, None)
            off = int(path.split("offset=")[1]); return [{"id": i} for i in range(off, min(off + 1000, 2500))]
        with mock.patch("hq._request", side_effect=req):
            with self.assertRaises(B.BackupError):
                B.dump()

    def test_sequences_come_from_the_schema_read_after_the_data(self):
        reads = {"n": 0}
        def req(method, path, body=None, prefer=None, timeout=30, exact=False):
            if path.endswith("/rpc/backup_schema"):
                reads["n"] += 1
                return {**SCHEMA, "sequences": [{"name": "s", "last_value": 100 * reads["n"]}]}
            return fake_request(method, path, body, prefer)
        with mock.patch("hq._request", side_effect=req):
            blob, _ = B.dump()
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
            seq = json.loads(tar.extractfile("schema.json").read())["sequences"][0]["last_value"]
        self.assertEqual(seq, 200)   # the second (after-data) read, not the first

    def test_table_list_changing_during_backup_is_refused(self):
        reads = {"n": 0}
        def req(method, path, body=None, prefer=None, timeout=30, exact=False):
            if path.endswith("/rpc/backup_schema"):
                reads["n"] += 1
                return SCHEMA if reads["n"] == 1 else {**SCHEMA, "tables": SCHEMA["tables"] + [{"name": "newtable"}]}
            return fake_request(method, path, body, prefer)
        with mock.patch("hq._request", side_effect=req):
            with self.assertRaises(B.BackupError):
                B.dump()

    def test_generic_put_without_name_placeholder_is_rejected(self):
        with mock.patch.dict(os.environ, {"BACKUP_KEY": KEY, "BACKUP_PUT_URL": "https://store.example.com/backup"}):
            with self.assertRaises(B.BackupError):
                B.put_files({"a.enc": b"1", "a.enc.sha256": b"2"})
            self.assertEqual(next(r["status"] for r in B.preflight() if "{name}" in r["check"]), "fail")

    def test_network_error_and_expired_token_are_retried_with_a_fresh_upload_url(self):
        with FakeB2() as fake:
            ps = b2_patches(fake)
            real = B._call; seen = {"n": 0}
            def flaky(method, url, headers, body=None, timeout=120):
                if "b2_upload" in url or "/upload" in url or url.startswith(fake.url) and body and len(body) > 1000:
                    seen["n"] += 1
                    if seen["n"] == 1:
                        raise urllib.error.URLError("connection reset")
                    if seen["n"] == 2:
                        return 401, json.dumps({"code": "expired_auth_token"}).encode()
                return real(method, url, headers, body, timeout)
            with mock.patch.dict(os.environ, b2_env(fake)), mock.patch("hq._request", side_effect=FakeStore()), ps[0], ps[1], mock.patch.object(B, "_call", flaky):
                out = B.run(force=True)
            self.assertTrue(out["ok"], out)
            self.assertEqual(len([f for f in fake.files if f["fileName"].endswith(".enc")]), 1)

    def test_failure_backoff_cap_and_single_message(self):
        night = datetime(2026, 11, 13, 8, 0, tzinfo=timezone.utc)
        def state(fails):
            def req(method, path, body=None, prefer=None, timeout=30, exact=False):
                if "action=eq.backup_failed" in path:
                    return fails
                return []
            return req
        recent = [{"at": "2026-11-13T07:50:00+00:00"}]
        with mock.patch("hq._request", side_effect=state(recent)):
            self.assertFalse(B.due(night))                                   # failed 10 min ago: wait
        with mock.patch("hq._request", side_effect=state([{"at": "2026-11-13T05:00:00+00:00"}])):
            self.assertTrue(B.due(night))                                    # failed 3 h ago: retry
        three = [{"at": f"2026-11-13T0{h}:00:00+00:00"} for h in (6, 5, 4)]
        with mock.patch("hq._request", side_effect=state(three)):
            self.assertFalse(B.due(datetime(2026, 11, 13, 9, 30, tzinfo=timezone.utc)))   # daily cap reached

    def test_failure_messages_owner_only_for_the_first_failure_of_the_day(self):
        sent = []
        def req_for(prior):
            def req(method, path, body=None, prefer=None, timeout=30, exact=False):
                if method == "POST" and path.endswith("/owner_messages"):
                    sent.append(body["body"]); return None
                if method == "POST":
                    return None
                if "action=eq.backup_failed" in path:
                    return prior
                if path.endswith("/rpc/backup_schema"):
                    raise urllib.error.HTTPError(path, 500, "x", {}, None)
                return fake_request(method, path, body, prefer)
            return req
        with mock.patch.dict(os.environ, ENV):
            with mock.patch("hq._request", side_effect=req_for([])):
                B.run(force=True)
            with mock.patch("hq._request", side_effect=req_for([{"at": "2026-11-13T05:00:00+00:00"}])):
                B.run(force=True)
        self.assertEqual(len(sent), 1)

    def test_owner_message_failure_does_not_turn_a_good_backup_into_a_failure(self):
        audits = []
        def req(method, path, body=None, prefer=None, timeout=30, exact=False):
            if method == "POST" and path.endswith("/owner_messages"):
                raise urllib.error.URLError("down")
            if method == "POST" and path.endswith("/audit_log"):
                audits.append(body["action"]); return None
            if method == "POST" and not path.endswith(("/rpc/backup_schema", "/rpc/backup_export_policy")):
                return None
            return fake_request(method, path, body, prefer)
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=req), \
             mock.patch.object(B, "put_files", return_value={"target": "t", "files": {}}), \
             mock.patch.object(B, "dump", wraps=B.dump) as d:
            # force an inconsistent dump so the owner message path runs
            orig = B._read_consistent
            with mock.patch.object(B, "_read_consistent", lambda n, s: (orig(n, s)[0], {"consistent": False, "method": "x", "attempts": 3})):
                r = B.run(force=True)
        self.assertTrue(r["ok"]); self.assertEqual(audits, ["backup_ok"])

    def test_concurrent_run_is_refused(self):
        self.assertTrue(B._RUN_LOCK.acquire(blocking=False))
        try:
            with mock.patch.dict(os.environ, ENV):
                self.assertEqual(B.run(force=True)["reason"], "a backup is already running")
        finally:
            B._RUN_LOCK.release()


class Crypto(unittest.TestCase):
    def setUp(self):
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=fake_request):
            self.blob, self.m = B.dump()
            self.enc = B.encrypt(self.blob)

    def test_roundtrip_and_ciphertext_hides_content(self):
        with mock.patch.dict(os.environ, ENV):
            self.assertEqual(B.verify(self.enc, self.m), [])
        self.assertNotIn(b"leads0", self.enc); self.assertNotIn(b"caf", self.enc)

    def test_tampered_ciphertext_is_detected(self):
        bad = bytearray(self.enc); bad[len(bad) // 2] ^= 1
        with mock.patch.dict(os.environ, ENV):
            self.assertTrue(B.verify(bytes(bad), self.m))
            self.assertTrue(B.verify(b"garbage", self.m))

    def test_wrong_key_detected(self):
        with mock.patch.dict(os.environ, {**ENV, "BACKUP_KEY": Fernet.generate_key().decode()}):
            self.assertTrue(B.verify(self.enc, self.m))

    def test_manifest_mismatch_detected(self):
        with mock.patch.dict(os.environ, ENV):
            self.assertTrue(B.verify(self.enc, {**self.m, "tables": {**self.m["tables"], "ideas": {**self.m["tables"]["ideas"], "rows": 4}}}))
            self.assertTrue(B.verify(self.enc, {**self.m, "tables": {**self.m["tables"], "ideas": {**self.m["tables"]["ideas"], "sha256": "0" * 64}}}))


class B2(unittest.TestCase):
    def run_backup(self, fake, env=None):
        store = FakeStore()
        ps = b2_patches(fake)
        with mock.patch.dict(os.environ, env or b2_env(fake)), mock.patch("hq._request", side_effect=store), ps[0], ps[1]:
            return B.run(force=True), store

    def test_success_uploads_encrypted_file_and_sha256_sidecar(self):
        import hashlib
        with FakeB2() as fake:
            out, store = self.run_backup(fake)
            self.assertTrue(out["ok"], out); self.assertTrue(out["complete"])
            names = sorted(f["fileName"] for f in fake.files)
            self.assertEqual(len(names), 2); self.assertTrue(names[0].startswith("hq/hq-") and names[0].endswith(".tar.gz.enc"))
            self.assertTrue(names[1].endswith(".enc.sha256"))
            enc = next(f["bytes"] for f in fake.files if f["fileName"].endswith(".enc"))
            side = next(f["bytes"] for f in fake.files if f["fileName"].endswith(".sha256")).decode()
            self.assertEqual(side.split()[0], hashlib.sha256(enc).hexdigest()); self.assertEqual(out["sha256"], side.split()[0])
            self.assertNotIn(b"leads0", enc)
            audit = [b for p, b in store.posts if p.endswith("/audit_log")][0]
            self.assertEqual(audit["action"], "backup_ok"); self.assertEqual(audit["detail"]["sha256"], out["sha256"])
            self.assertTrue(audit["detail"]["b2_file_id"])

    def test_retries_on_503_with_a_fresh_upload_url(self):
        with FakeB2() as fake:
            fake.fail_uploads = 2
            out, _ = self.run_backup(fake)
            self.assertTrue(out["ok"], out); self.assertGreaterEqual(fake.upload_calls, 3)

    def test_gives_up_after_repeated_503(self):
        with FakeB2() as fake:
            fake.fail_uploads = 99
            out, store = self.run_backup(fake)
            self.assertFalse(out["ok"]); self.assertIn("HTTP 503", out["reason"])
            self.assertEqual([b["action"] for p, b in store.posts if p.endswith("/audit_log")], ["backup_failed"])

    def test_detects_when_storage_acknowledges_a_different_checksum(self):
        with FakeB2() as fake:
            fake.corrupt_next_ack = True
            out, _ = self.run_backup(fake)
            self.assertFalse(out["ok"]); self.assertIn("different size or checksum", out["reason"])

    def test_wrong_key_and_missing_capability_fail_cleanly(self):
        with FakeB2() as fake:
            out, _ = self.run_backup(fake, b2_env(fake, "keyW:WRONG"))
            self.assertFalse(out["ok"]); self.assertIn("authorize failed", out["reason"])
            out, _ = self.run_backup(fake, b2_env(fake, "keyR:secretR"))   # read key cannot write
            self.assertFalse(out["ok"]); self.assertIn("get_upload_url failed", out["reason"])
            self.assertEqual(fake.files, [])

    def test_bad_target_strings(self):
        for url in ("b2://", "b2://short", "b2://abc def/x", "ftp://x"):
            with FakeB2() as fake, mock.patch.dict(os.environ, {"BACKUP_KEY": KEY, "BACKUP_PUT_URL": url, "BACKUP_AUTH": "a:b"}):
                self.assertFalse(B.upload("n", b"x"))

    def test_secrets_never_appear_in_audit_owner_message_logs_or_result(self):
        secrets = [KEY, "secretW", "keyW:secretW"]
        with FakeB2() as fake:
            fake.fail_uploads = 99
            with self.assertLogs(level="DEBUG") as logs:
                logging.getLogger().debug("probe")
                out, store = self.run_backup(fake)
            blob = json.dumps([out, store.posts, logs.output], default=str)
            for s in secrets + list(fake.tokens):
                self.assertNotIn(s, blob)

    def test_real_host_check_rejects_foreign_and_plain_http_urls(self):
        self.assertTrue(B._b2_ok_url("https://api004.backblazeb2.com"))
        self.assertTrue(B._b2_ok_url("https://pod-000-1111-02.backblaze.com".replace("backblaze.com", "backblazeb2.com")))
        for u in ("http://api.backblazeb2.com", "https://evil.example.com", "https://backblazeb2.com.evil.io", "https://x.backblazeb2.com.evil.io/a", ""):
            self.assertFalse(B._b2_ok_url(u), u)

    def test_authorize_refuses_a_response_pointing_at_a_foreign_host(self):
        def evil(method, url, headers, body=None, timeout=120):
            return 200, json.dumps({"authorizationToken": "t", "apiInfo": {"storageApi": {"apiUrl": "https://evil.example.com"}}}).encode()
        with mock.patch.object(B, "_call", side_effect=evil), self.assertRaises(B.BackupError):
            B.b2_authorize("k:v")


class GenericPut(unittest.TestCase):
    def test_put_target_sends_both_files_and_auth_header(self):
        seen = []
        def call(method, url, headers, body=None, timeout=120):
            seen.append((method, url, headers.get("Authorization"))); return 201, b""
        with mock.patch.dict(os.environ, {**ENV, "BACKUP_AUTH": "Basic abc"}), mock.patch.object(B, "_call", side_effect=call):
            self.assertTrue(B.upload("a b.enc", b"x"))
        self.assertEqual(seen[0], ("PUT", "https://store.example.com/b/a%20b.enc", "Basic abc"))

    def test_put_target_failure_status(self):
        with mock.patch.dict(os.environ, ENV), mock.patch.object(B, "_call", return_value=(403, b"")):
            self.assertFalse(B.upload("x", b"y"))

    def test_rejects_non_https_target(self):
        with mock.patch.dict(os.environ, {**ENV, "BACKUP_PUT_URL": "http://insecure/{name}"}):
            self.assertFalse(B.upload("x", b"y"))


class GenericPutRetry(unittest.TestCase):
    def test_transient_5xx_and_network_errors_are_retried_then_succeed(self):
        seq = iter([(503, b""), urllib.error.URLError("down"), (201, b"")])
        def call(method, url, headers, body=None, timeout=120):
            r = next(seq)
            if isinstance(r, Exception): raise r
            return r
        with mock.patch.dict(os.environ, ENV), mock.patch.object(B, "_call", side_effect=call):
            self.assertEqual(B.put_files({"a": b"x"})["files"]["a"]["bytes"], 1)

    def test_final_errors_are_not_retried_and_name_what_to_check(self):
        calls = []
        def call(method, url, headers, body=None, timeout=120):
            calls.append(1); return 401, b"secret-body"
        with mock.patch.dict(os.environ, {**ENV, "BACKUP_AUTH": "tok-123"}), mock.patch.object(B, "_call", side_effect=call):
            with self.assertRaises(B.BackupError) as cm: B.put_files({"a": b"x"})
        self.assertEqual(len(calls), 1); self.assertIn("BACKUP_AUTH", str(cm.exception)); self.assertNotIn("tok-123", str(cm.exception)); self.assertNotIn("store.example.com", str(cm.exception))

    def test_network_down_gives_bounded_retries_and_clear_message(self):
        n = []
        def call(*a, **k):
            n.append(1); raise urllib.error.URLError("refused https://store.example.com/b/x?token=SECRET")
        with mock.patch.dict(os.environ, ENV), mock.patch.object(B, "_call", side_effect=call):
            with self.assertRaises(B.BackupError) as cm: B.put_files({"a": b"x"})
        self.assertEqual(len(n), B.PUT_ATTEMPTS); self.assertIn("unreachable", str(cm.exception)); self.assertNotIn("SECRET", str(cm.exception))

    def test_sidecar_failure_is_reported_as_partial(self):
        def call(method, url, headers, body=None, timeout=120):
            return (201, b"") if url.endswith("/f.enc") else (500, b"")
        with mock.patch.dict(os.environ, ENV), mock.patch.object(B, "_call", side_effect=call):
            with self.assertRaises(B.BackupError) as cm: B.put_files({"f.enc": b"x", "f.enc.sha256": b"y"})
        self.assertIn("checksum file was not", str(cm.exception))

    def test_invalid_key_message_is_clear_and_does_not_echo_the_value(self):
        with mock.patch.dict(os.environ, {**ENV, "BACKUP_KEY": "super-secret-not-a-key"}):
            with self.assertRaises(B.BackupError) as cm: B.encrypt(b"x")
        self.assertIn("BACKUP_KEY", str(cm.exception)); self.assertNotIn("super-secret", str(cm.exception))

    def test_owner_alert_uses_a_kind_the_table_allows(self):
        store = FakeStore()
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=store), mock.patch.object(B, "put_files", side_effect=B.BackupError("x")):
            B.run(force=True)
        kinds = [b["kind"] for p, b in store.posts if p.endswith("/owner_messages")]
        self.assertTrue(kinds); self.assertTrue(set(kinds) <= {"brief", "money", "health", "contract", "proposal", "emergency"})


class Run(unittest.TestCase):
    def test_run_success_and_failure_paths(self):
        store = FakeStore()
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=store):
            with mock.patch.object(B, "put_files", return_value={"target": "put", "files": {}}):
                r = B.run(force=True); self.assertTrue(r["ok"]); self.assertEqual(r["rows"], 8)
            with mock.patch.object(B, "put_files", side_effect=B.BackupError("upload of x failed (HTTP 500)")):
                r = B.run(force=True); self.assertFalse(r["ok"]); self.assertIn("HTTP 500", r["reason"])
        self.assertTrue(any("Backup failed" in (b or {}).get("body", "") for p, b in store.posts))

    def test_unexpected_exception_text_is_not_leaked(self):
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=fake_request), \
             mock.patch.object(B, "put_files", side_effect=RuntimeError("secret " + KEY)):
            r = B.run(force=True)
        self.assertFalse(r["ok"]); self.assertNotIn(KEY, json.dumps(r))

    def test_incomplete_backup_succeeds_but_tells_the_owner(self):
        store = FakeStore()
        def req(method, path, body=None, prefer=None, timeout=30, exact=False):
            return no_schema_request(method, path, body, prefer) if method == "GET" or path.endswith("backup_schema") else store(method, path, body, prefer)
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=req), \
             mock.patch.object(B, "put_files", return_value={"target": "put", "files": {}}):
            r = B.run(force=True)
        self.assertTrue(r["ok"]); self.assertFalse(r["complete"])

    def test_due_window(self):
        with mock.patch("hq._request", return_value=[]):
            self.assertTrue(B.due(datetime(2026, 11, 13, 8, 0, tzinfo=timezone.utc)))    # 03:00 Toronto
            self.assertFalse(B.due(datetime(2026, 11, 13, 18, 0, tzinfo=timezone.utc)))  # 13:00 Toronto
        with mock.patch("hq._request", return_value=[{"id": 1}]):
            self.assertFalse(B.due(datetime(2026, 11, 13, 8, 0, tzinfo=timezone.utc)))   # already done

    def test_last_ok(self):
        with mock.patch("hq._request", return_value=[{"at": "2026-11-13T07:00:00Z", "detail": {"file": "f", "sha256": "ab"}}]):
            self.assertEqual(B.last_ok()["file"], "f")
        with mock.patch("hq._request", return_value=[]):
            self.assertIsNone(B.last_ok())


if __name__ == "__main__":
    unittest.main()


class LeakRedaction(unittest.TestCase):
    """The second lock in code for the client-text leak paths (audit_log.detail, ledger.note, tasks.result, agent_runs.summary)."""
    TABLES = Snapshot.TABLES

    def req(self, data, redaction=None, drop_redaction=False):
        def r(method, path, body=None, prefer=None, timeout=30, exact=False):
            if path.endswith("/rpc/backup_snapshot"):
                snap = {"data": data, "schema": {**SCHEMA, "tables": [{"name": n} for n in self.TABLES + ["push_config"]]}, "method": "x", "policy": POLICY}
                if not drop_redaction:
                    snap["redaction"] = redaction if redaction is not None else REDACTION
                return snap
            return fake_request(method, path, body, prefer, exact=exact)
        return r

    def test_snapshot_without_redaction_is_refused_and_not_downgraded(self):
        data = {"ideas": [], "ledger": [{"id": 1, "note": "Setter payout (close): Sam Setter"}], "tasks": []}
        with mock.patch("hq._request", side_effect=self.req(data, drop_redaction=True)):
            with self.assertRaises(B.BackupError) as e:
                B.dump()
        self.assertIn("did not redact", str(e.exception))
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=self.req(data, drop_redaction=True)):
            self.assertFalse(B.run(force=True)["ok"])

    def test_redaction_spec_must_cover_all_four_paths(self):
        thin = {"version": 2, "spec": [{"table_name": "ledger", "column_name": "note"}]}
        with mock.patch("hq._request", side_effect=self.req({"ideas": [], "ledger": [], "tasks": []}, redaction=thin)):
            with self.assertRaises(B.BackupError) as e:
                B.dump()
        self.assertIn("audit_log.detail", str(e.exception))
        with mock.patch("hq._request", side_effect=self.req({"ideas": [], "ledger": [], "tasks": []}, redaction={"version": 0, "spec": REDACTION["spec"]})):
            with self.assertRaises(B.BackupError):
                B.dump()

    def test_contact_data_surviving_in_a_strict_column_blocks_the_backup(self):
        for bad in ({"ledger": [{"id": 1, "note": "paid jane.doe@example.com"}]}, {"ledger": [{"id": 1, "note": "call 613-555-0142"}]},
                    {"tasks": [{"id": 1, "result": "x 6135550142 y"}]}):
            data = {"ideas": [], "ledger": [], "tasks": [], **bad}
            with mock.patch("hq._request", side_effect=self.req(data)):
                with self.assertRaises(B.BackupError) as e:
                    B.dump()
            self.assertIn("refusing to write the backup", str(e.exception))

    def test_clean_and_failed_closed_fields_pass_and_are_counted(self):
        data = {"ideas": [], "ledger": [{"id": 1, "note": "deal 3f2a1b4c-1111-4222-8333-444455556666: owner confirmed win", "amount_cents": 250000}],
                "tasks": [{"id": 1, "result": B.UNCERTAIN}, {"id": 2, "result": "Done: 4 prospects"}]}
        with mock.patch("hq._request", side_effect=self.req(data)):
            blob, m = B.dump()
        self.assertEqual(m["redaction"]["mode"], "database"); self.assertEqual(m["redaction"]["fields_failed_closed"], {"tasks.result": 1})
        self.assertIn("ledger.note", m["redaction"]["columns"]); self.assertIn("agent_runs.summary", m["redaction"]["columns"])
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
            self.assertIn(b"250000", tar.extractfile("data/ledger.jsonl").read())

    def test_fallback_never_exports_the_free_text_of_the_leak_columns(self):
        rows = {"ideas": [{"id": 1, "v": "keep me"}], "ledger": [{"id": 1, "kind": "expense", "amount_cents": 36000, "note": "Setter payout (close): Sam Setter"}],
                "tasks": [{"id": 1, "status": "done", "title": "Follow up Jean Tremblay", "detail": "call 613-555-0142", "result": "Jean Tremblay jean@x.com"}]}
        def r(method, path, body=None, prefer=None, timeout=30, exact=False):
            if path.endswith("/rpc/backup_snapshot"):
                raise urllib.error.HTTPError(path, 404, "no function", {}, None)
            if method == "GET" and "/rest/v1/" in path and "audit_log" not in path:
                t = path.split("/rest/v1/")[1].split("?")[0]
                return rows.get(t, []) if "offset=0" in path else []
            return fake_request(method, path, body, prefer, exact=exact)
        with mock.patch("hq._request", side_effect=r):
            blob, m = B.dump()
        self.assertEqual(m["redaction"]["mode"], "fallback_blanked")
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
            allj = b"".join(tar.extractfile(n).read() for n in tar.getnames() if n.startswith("data/"))
        for secret in (b"Tremblay", b"Sam Setter", b"613-555", b"jean@x.com"):
            self.assertNotIn(secret, allj)
        self.assertIn(b"36000", allj); self.assertIn(b'"status":"done"', allj); self.assertIn(b"keep me", allj)

    def test_blank_keeps_json_structure_numbers_and_booleans(self):
        out = B.blank_leak_columns("audit_log", [{"id": 7, "action": "do_not_contact", "detail": {"leads_marked": 2, "ok": True, "reason": "Jean 613-555-0142", "ids": ["a", 3]}}])[0]
        self.assertEqual(out["detail"], {"[redacted:key0]": 2, "[redacted:key1]": True, "[redacted:key2]": B.UNCERTAIN, "[redacted:key3]": [B.UNCERTAIN, 3]}); self.assertEqual(out["action"], "do_not_contact")
        self.assertEqual(B.blank_leak_columns("ideas", [{"id": 1, "v": "x"}]), [{"id": 1, "v": "x"}])


class LeakRedactionV2(unittest.TestCase):
    """Findings 3, 4 and 6 in code: spec-driven strict columns, JSON numbers, table.column reporting without values, paged export."""
    SPEC = REDACTION["spec"] + [{"table_name": "ideas", "column_name": "v", "kind": "text", "mode": "strict", "max_len": 500},
                                {"table_name": "ledger", "column_name": "detail", "kind": "json", "mode": "strict", "max_len": 500}]

    def test_strict_columns_come_from_the_snapshot_spec(self):
        sc = B.strict_columns(self.SPEC)
        self.assertIn("v", sc["ideas"]); self.assertIn("detail", sc["ledger"]); self.assertIn("note", sc["ledger"])
        data = {"ideas": [{"id": 1, "v": "mail jane.doe@example.com"}]}
        with self.assertRaises(B.BackupError) as e:
            B.assert_redacted(data, self.SPEC)
        self.assertIn("ideas.v", str(e.exception)); self.assertNotIn("jane", str(e.exception))
        B.assert_redacted(data)   # without the spec only the four floor columns are known: shows why the spec is passed

    def test_json_numbers_phone_sin_like_are_refused_but_amounts_pass(self):
        for bad in ({"detail": {"ph": 6135550199, "ssn": 123456789}}, {"detail": {"contact": 6135550199}}, {"detail": [{"x": 123456789}]}):
            with self.assertRaises(B.BackupError) as e:
                B.assert_redacted({"audit_log": [{"id": 1, **bad}]})
            self.assertIn("audit_log.detail", str(e.exception)); self.assertNotIn("6135550199", str(e.exception))
        B.assert_redacted({"audit_log": [{"id": 1, "detail": {"amount": 12345678, "cents": 1500000, "txid": 99887766, "count": 3, "price": 1234567.5}}]})

    def test_report_names_table_and_column_for_every_failing_column_never_the_value(self):
        data = {"ledger": [{"id": 1, "note": "ab@cd.example"}], "tasks": [{"id": 1, "result": "613-555-0199"}, {"id": 2, "result": "612-555-0100"}]}
        with self.assertRaises(B.BackupError) as e:
            B.assert_redacted(data)
        m = str(e.exception)
        self.assertIn("ledger.note (1 field(s))", m); self.assertIn("tasks.result (2 field(s))", m)
        for v in ("ab@cd.example", "613-555", "612-555"):
            self.assertNotIn(v, m)

    def test_fallback_blanks_every_listed_free_text_column(self):
        for t, c in (("web_messages", "body"), ("action_log", "reason"), ("bank_transactions", "description"), ("missions", "objective"), ("payment_instructions", "payee"), ("evidence_sources", "text")):
            self.assertEqual(B.blank_leak_columns(t, [{"id": 1, c: "Jean Tremblay"}])[0][c], B.UNCERTAIN, (t, c))

    def _paged_req(self, mutate_after_pages=False):
        state = {"digest": 0, "pages": []}
        rows = {"ideas": [{"id": i, "v": f"idea{i}"} for i in range(450)], "ledger": [], "tasks": []}
        def r(method, path, body=None, prefer=None, timeout=30, exact=False):
            if path.endswith("/rpc/backup_snapshot_cost"):
                return {"est_seconds": 600.0, "strict_chars": 1, "light_chars": 1, "field_count": 1}
            if path.endswith("/rpc/backup_redaction_meta"):
                return {"version": 2, "spec": REDACTION["spec"], "unclassified_columns": []}
            if path.endswith("/rpc/backup_table_digest"):
                if mutate_after_pages and state["pages"]:
                    state["digest"] += 1
                return {"rows": 1, "md5": f"{body['p_table']}-{state['digest']}"}
            if path.endswith("/rpc/backup_snapshot_page"):
                state["pages"].append((body["p_table"], body["p_offset"]))
                return {"rows": rows[body["p_table"]][body["p_offset"]: body["p_offset"] + body["p_limit"]], "n": 0, "ms": 1}
            if path.endswith("/rpc/backup_snapshot"):
                raise AssertionError("single statement used although the cost estimate is over the budget")
            return fake_request(method, path, body, prefer, exact=exact)
        return r, state

    def test_paged_export_when_estimate_is_over_budget(self):
        r, state = self._paged_req()
        with mock.patch("hq._request", side_effect=r):
            blob, m = B.dump()
        self.assertEqual(m["redaction"]["mode"], "database_paged"); self.assertEqual(m["tables"]["ideas"]["rows"], 450)
        self.assertTrue(m["consistency"]["consistent"])
        self.assertEqual([o for t, o in state["pages"] if t == "ideas"], [0, 200, 400, 450])

    def test_paged_export_flags_a_table_that_changed_while_reading(self):
        r, _ = self._paged_req(mutate_after_pages=True)
        with mock.patch("hq._request", side_effect=r):
            _, m = B.dump()
        self.assertFalse(m["consistency"]["consistent"]); self.assertTrue(m["consistency"]["changing_tables"])

    def test_paged_export_without_redaction_meta_is_refused(self):
        r, _ = self._paged_req()
        def r2(method, path, *a, **k):
            if path.endswith("/rpc/backup_redaction_meta"):
                return {"version": 1, "spec": []}
            return r(method, path, *a, **k)
        with mock.patch("hq._request", side_effect=r2):
            with self.assertRaises(B.BackupError):
                B.dump()


class FallbackMatchesSpec(unittest.TestCase):
    """Re-review finding 3: the fallback blanked 35 of 117 strict/light columns (a hand list). It is now derived from backup_redaction_spec()."""
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts"))
        import gen_backup_keep
        cls.gen = gen_backup_keep
        cls.rows = gen_backup_keep.spec()

    def test_generated_keep_file_is_current(self):
        self.assertEqual(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "hq_backup_keep.py")).read(), self.gen.render(), "run python3 scripts/gen_backup_keep.py")

    def test_the_spec_has_the_expected_shape(self):
        self.assertGreater(len(self.rows), 200)
        self.assertGreater(sum(1 for r in self.rows if r[3] in ("strict", "light")), 100)

    def test_every_strict_light_and_blank_column_is_blanked_by_the_fallback(self):
        import hq_backup_keep
        real_keep = hq_backup_keep.KEEP
        for t, c, kind, mode in self.rows:
            val = {"a": "Jean Tremblay 613-555-0142"} if kind == "json" else ["Jean Tremblay"] if kind == "array" else "Jean Tremblay 613-555-0142"
            out = B.blank_leak_columns(t, [{"id": 1, c: val}])[0]
            if mode == "keep":
                self.assertEqual(out[c], val, (t, c))
            else:
                self.assertNotIn("Tremblay", json.dumps(out[c]), (t, c, mode))
                self.assertNotIn("613-555", json.dumps(out[c]), (t, c, mode))

    def test_json_keys_numbers_and_bools_are_blanked_in_a_non_keep_json_column(self):
        """Round 3 S2: only string VALUES were blanked, so a key ('jpicardeau', 'Luc Picardeau') or a number (a phone) survived in the fallback export."""
        val = {"Luc Picardeau": 1, "a": {"jpicardeau": True, "ph": 6135550199}, "arr": [6135550198, {"x": 2.5}, "Jean Tremblay"]}
        t, c = next((t, c) for t, c, kind, mode in self.rows if kind == "json" and mode == "strict")
        out = B.blank_leak_columns(t, [{"id": 1, c: val}])[0][c]
        txt = json.dumps(out)
        for bad in ("Picardeau", "jpicardeau", "6135550199", "6135550198", "Tremblay"):
            self.assertNotIn(bad, txt)
        self.assertEqual(sorted(out.keys())[0].startswith("[redacted:key"), True)
        self.assertIs(list(out.values())[1]["[redacted:key0]"], True)     # structure kept: a bool stays a bool, a small number stays
        self.assertEqual(list(out.values())[1]["[redacted:key1]"], 0)       # the 10-digit number (a phone) is gone
        self.assertEqual(list(out.values())[0], 1)
        B.assert_redacted({t: [{c: out}]})                                  # the second lock passes on the fallback output

    def test_a_column_nobody_classified_is_blanked_and_plain_ids_survive(self):
        out = B.blank_leak_columns("ideas", [{"id": "3f2a1b4c-1111-4222-8333-444455556666", "zz_new_note": "Jean Tremblay", "created_at": "2026-11-15T10:30:00+00:00", "n": 5, "ok": True, "status": "new"}])[0]
        self.assertEqual((out["zz_new_note"], out["id"], out["created_at"], out["n"], out["ok"], out["status"]), (B.UNCERTAIN, "3f2a1b4c-1111-4222-8333-444455556666", "2026-11-15T10:30:00+00:00", 5, True, "new"))
