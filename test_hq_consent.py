"""hq_consent: the Python mirrors of the SQL consent-integrity primitives. The SQL side is tested by sqltests/consent_integrity_check.sql against the SAME phone table
and the SAME constants (a seal, a key fingerprint, a keyed contact hash, an HMAC vector), so a drift in either implementation fails a test on one side."""
import datetime as dt
import hashlib
import hmac
import os
import re
import unittest

import hq_consent as C

HERE = os.path.dirname(os.path.abspath(__file__))
K1 = "capture-key-0123456789abcdef0123456789abcdef0123456789abcdef"
K2 = "suppr-key-fedcba9876543210fedcba9876543210fedcba9876543210"


def phone_cases():
    out = []
    with open(os.path.join(HERE, "sqltests", "data", "phone_cases.tsv"), encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            a, b = line.split("\t")
            out.append((a, None if b == "\\N" else b))
    return out


class Phone(unittest.TestCase):
    def test_shared_table_with_the_sql_test(self):
        cases = phone_cases()
        self.assertGreater(len(cases), 40)
        for a, want in cases:
            self.assertEqual(C.normalize_phone(a), want, repr(a))

    def test_idempotent(self):
        for a, _ in phone_cases():
            n = C.normalize_phone(a)
            self.assertEqual(C.normalize_phone(n), n, repr(a))

    def test_invisible_and_none(self):
        self.assertIsNone(C.normalize_phone(None))
        self.assertEqual(C.normalize_phone("613​-555-0101‎"), "+16135550101")

    def test_formats_collapse_to_one_key(self):
        forms = ["+1 (613) 555-0101", "613.555.0101", "1-613-555-0101", "٦١٣٥٥٥٠١٠١", "＋１６１３５５５０１０１", "(613)5550101", "6135550101 x9"]
        self.assertEqual({C.normalize_phone(f) for f in forms}, {"+16135550101"})

    def test_ambiguous_or_unusable_is_none(self):
        for bad in ["555-0101", "1-800-FLOWERS", "44 20 7946 0958", "613-555-0101, 613-555-0102", "+1 (013) 555-0101", "call me 613-555-0101", ""]:
            self.assertIsNone(C.normalize_phone(bad), bad)


class Primitives(unittest.TestCase):
    def test_hmac_vectors_match_sql_constants(self):
        self.assertEqual(C.hmac_hex("Jefe", "what do ya want for nothing?"), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")   # RFC 4231 case 2
        self.assertEqual(C.hmac_hex("a" * 100, "long key message"), "6fcbe469471764df18dbd2533610a340b4fa93abfcd975b046bd991b7293e347")
        self.assertEqual(C.hmac_hex(K1, "x"), hmac.new(K1.encode(), b"x", hashlib.sha256).hexdigest())

    def test_constants_shared_with_the_sql_test(self):
        at = dt.datetime(2026, 11, 1, 12, 0, 0, tzinfo=dt.timezone.utc)
        ws = "11111111-2222-3333-4444-555555555555"
        seal = C.capture_seal(K1, workspace_id=ws, capture_ref="form-abc-001", channel="email", wording_version="v1", wording_sha256="b" * 64,
                              captured_at=at, contact="Alice@Example.com", artifact_sha256="a" * 64)
        self.assertEqual(seal, "74638c180cc3bd0a142e81670dd5797d114575aaaf7510a6e06c7027ed1de48c")
        self.assertEqual(C.key_fingerprint(K1, "capture_signing_key"), "605f5ca79b545b565b02a8faf2f3c19a95d7abb59ffed4702992a4f0ffc83f93")
        self.assertEqual(C.contact_mac(K1, "email", "alice@example.com"), "f69d713627cf2e66dfb03ced3df76067c7a85daba98aeca2283f1cae9f1eef48")
        self.assertEqual(C.suppression_mac(K2, "email", "alice@example.com"), "c492facef016d7976c5c38aa3f229d20af79f35f107acdf8b9648986e516c448")

    def test_canonical_text_and_separator_guard(self):
        at = dt.datetime(2026, 11, 1, 12, 0, 0, tzinfo=dt.timezone.utc)
        t = C.capture_canonical("w", "ref-1", "sms", "v1", "B" * 64, at, "+1 613", "A" * 64)
        self.assertEqual(t, f"ffm-capture-v1|w|ref-1|sms|v1|{'b' * 64}|1793534400|+1 613|{'a' * 64}")   # hashes lower-cased, epoch seconds
        for bad in ({"capture_ref": "a|b"}, {"contact": "x|y"}, {"wording_version": "v|1"}):
            args = dict(workspace_id="w", capture_ref="ref-1", channel="sms", wording_version="v1", wording_sha256="b" * 64, captured_at=at, contact="c", artifact_sha256="a" * 64)
            args.update(bad)
            with self.assertRaises(ValueError):
                C.capture_canonical(**args)
        with self.assertRaises(ValueError):
            C.capture_canonical("w", "r-1-1", "sms", "v1", "b" * 64, dt.datetime(2026, 1, 1), "c", "a" * 64)   # naive time

    def test_a_different_key_gives_a_different_seal(self):
        at = dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc)
        kw = dict(workspace_id="w", capture_ref="ref-1", channel="sms", wording_version="v1", wording_sha256="b" * 64, captured_at=at, contact="c", artifact_sha256="a" * 64)
        self.assertNotEqual(C.capture_seal(K1, **kw), C.capture_seal(K2, **kw))


class SuppressionExport(unittest.TestCase):
    def export(self, macs=None):
        macs = macs if macs is not None else [("email", "a" * 64), ("phone", "b" * 64), ("email", "c" * 64)]
        d = C.suppression_digest(macs)
        return {"version": 1, "included": True, "key_check": "f" * 64, "macs": sorted([list(m) for m in macs]), **d}

    def test_digest_shape(self):
        d = C.suppression_digest([("email", "a" * 64), ("phone", "b" * 64)])
        self.assertEqual((d["count"], d["email_count"], d["phone_count"]), (2, 1, 1))
        self.assertEqual(d["hash"], hashlib.sha256(f"email:{'a' * 64}\nphone:{'b' * 64}".encode()).hexdigest())
        self.assertEqual(C.suppression_digest([])["hash"], hashlib.sha256(b"").hexdigest())

    def test_valid(self):
        self.assertEqual(C.validate_suppression_export(self.export()), [])
        self.assertEqual(C.validate_suppression_export(self.export([])), [])

    def test_tampering_is_reported(self):
        e = self.export(); e["macs"] = e["macs"][1:]
        self.assertTrue(C.validate_suppression_export(e))
        e = self.export(); e["macs"][0][1] = "0" * 64
        self.assertTrue(C.validate_suppression_export(e))
        e = self.export(); e["macs"].append(e["macs"][0])
        self.assertTrue(C.validate_suppression_export(e))
        e = self.export(); e["count"] += 1
        self.assertTrue(C.validate_suppression_export(e))
        for bad in (None, {}, {"version": 2}, {"version": 1, "included": False, "reason": "no key"}, {"version": 1, "included": True, "macs": "x"},
                    {**self.export(), "macs": [["sms", "a" * 64]]}, {**self.export(), "macs": [["email", "XYZ"]]}, {**self.export(), "key_check": None}):
            self.assertTrue(C.validate_suppression_export(bad), bad)

    def test_a_plaintext_address_cannot_be_smuggled_in_as_a_mac(self):
        e = self.export(); e["macs"][0][1] = "alice@example.com"
        self.assertTrue(C.validate_suppression_export(e))


if __name__ == "__main__":
    unittest.main()
