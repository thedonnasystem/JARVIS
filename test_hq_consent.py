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
K1 = hashlib.sha256(b"fixture-capture-key").hexdigest()       # derived, never a key-shaped literal in the repository (the SQL test derives the same values)
K2 = hashlib.sha256(b"fixture-suppression-key").hexdigest()


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
        self.assertGreater(len(cases), 80)
        for a, want in cases:
            self.assertEqual(C.normalize_phone(a), want, repr(a))

    def test_idempotent(self):
        for a, _ in phone_cases():
            n = C.normalize_phone(a)
            self.assertEqual(C.normalize_phone(n), n, repr(a))

    def test_trunk_prefix_variants_collapse(self):
        """PR #15 review finding 4: '(0)' / a 0 after the country code is a trunk prefix in these countries, so the variants are ONE number."""
        groups = [["+44 (0)20 7946 0958", "+44 20 7946 0958", "+44 020 7946 0958", "0044 (0)20 7946 0958"],
                  ["+20 010 1234 5678", "+20 10 1234 5678", "+20 (0)10 1234 5678"],
                  ["+33 (0)1 23 45 67 89", "+33 1 23 45 67 89", "+33 01 23 45 67 89"],
                  ["+49 (0)30 12345678", "+49 30 12345678"], ["+61 (0)4 1234 5678", "+61 0412 345 678", "+61 412 345 678"],
                  ["+971 (0)50 123 4567", "+971 50 123 4567"], ["+966 (0)50 123 4567", "+966 50 123 4567"], ["+212 (0)6 12 34 56 78", "+212 6 12 34 56 78"],
                  ["+962 (0)7 9012 3456", "+962 7 9012 3456"], ["+961 (0)3 123 456", "+961 3 123 456"], ["+90 (0)212 345 67 89", "+90 212 345 67 89"]]
        for g in groups:
            got = {C.normalize_phone(x) for x in g}
            self.assertEqual(len(got), 1, g); self.assertIsNotNone(next(iter(got)), g)
        self.assertEqual(C.normalize_phone("+39 06 1234 5678"), "+390612345678")     # Italy keeps its 0

    def test_differential_fuzz_corpus_is_in_sync_and_unicode_separators_are_rejected(self):
        """Re-review item 3: 6,000 generated inputs (sqltests/data/phone_fuzz.tsv) run through BOTH implementations (this file; the SQL test runs the same rows). The corpus must equal what
        the generator produces from the Python mirror, so it cannot drift."""
        import subprocess, sys
        r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "scripts", "gen_phone_fuzz.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(HERE, "sqltests", "data", "phone_fuzz.tsv"), encoding="utf-8", newline="") as f:
            n = sum(1 for _ in f)
        self.assertGreaterEqual(n, 5000)
        for sep in ("\u2028", "\u2029", "\u1680"):
            self.assertIsNone(C.normalize_phone(f"+44{sep}20 7946 0958"), repr(sep))
            self.assertIsNone(C.normalize_phone(f"+44 20 7946 0958{sep}"), repr(sep))

    def test_trunk_zero_for_every_listed_country_and_fail_closed_for_the_rest(self):
        for cc, mob in (("31", "6 12345678"), ("353", "1 234 5678"), ("91", "98 1234 5678"), ("81", "90 1234 5678"), ("46", "70 123 45 67"), ("27", "82 123 4567"), ("41", "79 123 45 67"), ("972", "50 123 4567")):
            plain, trunk, par = f"+{cc} {mob}", f"+{cc} 0{mob}", f"+{cc} (0)" + mob
            self.assertIsNotNone(C.normalize_phone(plain), plain)
            self.assertEqual(C.normalize_phone(trunk), C.normalize_phone(plain), trunk)
            self.assertEqual(C.normalize_phone(par), C.normalize_phone(plain), par)
        for unknown in ("+977 01 123 4567", "+995 0 32 123 4567", "+977 (0)1 123 4567", "+36 0 20 123 4567"):
            self.assertIsNone(C.normalize_phone(unknown), unknown)
        self.assertEqual(C.cc_len("353123"), 3); self.assertEqual(C.cc_len("31612"), 2); self.assertEqual(C.cc_len("7912"), 1); self.assertEqual(C.cc_len("20101"), 2); self.assertEqual(C.cc_len("212612"), 3)

    def test_invisible_and_none(self):
        self.assertIsNone(C.normalize_phone(None))
        self.assertEqual(C.normalize_phone("613​-555-0101‎"), "+16135550101")

    def test_formats_collapse_to_one_key(self):
        forms = ["+1 (613) 555-0101", "613.555.0101", "1-613-555-0101", "٦١٣٥٥٥٠١٠١", "＋１６１３５５５０１０１", "(613)5550101", "6135550101 x9"]
        self.assertEqual({C.normalize_phone(f) for f in forms}, {"+16135550101"})

    def test_ambiguous_or_unusable_is_none(self):
        for bad in ["555-0101", "1-800-FLOWERS", "44 20 7946 0958", "613-555-0101, 613-555-0102", "+1 (013) 555-0101", "call me 613-555-0101", "",
                    "+39 (0)6 1234 5678", "+34 0612 345 678", "+44 00 20 7946 0958"]:
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
        self.assertEqual(seal, "e448ddc5532c39f7dc2ee7714767002c7ba4fc31d175e9df71aed4de32093dec")
        self.assertEqual(C.key_fingerprint(K1, "capture_signing_key"), "463f3361eb18a7c3ba64af73e7d03c4032bdd9ab4a5f58579212a34baa147b1d")
        self.assertEqual(C.contact_mac(K1, "email", "alice@example.com"), "cc176de0c0adc3013d93060a5d24064136f5dae6fd10be28b6c63aa773d768a0")
        self.assertEqual(C.suppression_mac(K2, "email", "alice@example.com"), "985f80f68e85610bf42950081d00a583be5d9280d69f126dac356d04334a7f18")

    def test_canonical_text_is_domain_separated_and_length_prefixed(self):
        at = dt.datetime(2026, 11, 1, 12, 0, 0, tzinfo=dt.timezone.utc)
        t = C.capture_canonical("w", "ref-1", "sms", "v1", "B" * 64, at, "+1 613", "A" * 64)
        self.assertEqual(t, f"cap|v1|1:w5:ref-13:sms2:v164:{'b' * 64}10:17935344006:+1 61364:{'a' * 64}")   # hashes lower-cased, epoch seconds, every field length-prefixed
        # PR #15 review finding 1: a colon or a bar inside capture_ref can no longer be used to re-split the string; the reference charset forbids both
        args = dict(workspace_id="w", capture_ref="ref-1", channel="sms", wording_version="v1", wording_sha256="b" * 64, captured_at=at, contact="c", artifact_sha256="a" * 64)
        for bad in ("forged:ref1", "a|b-1", "ab", "-abc", "a b c", ""):
            with self.assertRaises(ValueError, msg=bad):
                C.capture_canonical(**{**args, "capture_ref": bad})
        # fields that may contain anything (contact) still cannot move a boundary
        a = C.capture_canonical(**{**args, "wording_version": "v1", "contact": "x:1"})
        b = C.capture_canonical(**{**args, "wording_version": "v1x", "contact": ":1"})
        self.assertNotEqual(a, b)
        self.assertNotEqual(C.capture_canonical(**{**args, "capture_ref": "ab-1", "wording_version": "c"}), C.capture_canonical(**{**args, "capture_ref": "ab-", "wording_version": "1c"}))
        with self.assertRaises(ValueError):
            C.capture_canonical("w", "r-1-1", "sms", "v1", "b" * 64, dt.datetime(2026, 1, 1), "c", "a" * 64)   # naive time

    def test_domains_never_collide(self):
        """One key used for two purposes (the reviewer's attack needed this) still cannot produce a message of the other domain."""
        k = K1
        self.assertTrue(C.sup_message("email", "x").startswith("sup|v1|"))
        self.assertNotEqual(C.suppression_mac(k, "email", "a@b.co"), C.contact_mac(k, "email", "a@b.co"))
        self.assertNotEqual(C.suppression_mac(k, "email", "a@b.co"), C.key_fingerprint(k, "email"))
        # the old oracle message: kind || ':' || norm. The attacker chose kind and norm so that it equalled the canonical capture text. Not possible now:
        at = dt.datetime(2026, 11, 1, 12, tzinfo=dt.timezone.utc)
        canon = C.capture_canonical("w", "ref-1", "email", "v1", "b" * 64, at, "victim@example.com", "a" * 64)
        for cut in range(len(canon)):
            self.assertNotEqual(C.sup_message(canon[:cut], canon[cut:]), canon)
        self.assertFalse(canon.startswith("sup|v1|"))

    def test_fractional_seconds_truncate_like_sql_floor(self):
        """Re-review item 2: SQL floor(extract(epoch)), not a rounding cast. 12:00:00.75 and 12:00:00 give the same canonical text; so does 11:59:59.999999 -> ...:59."""
        base = dict(workspace_id="w", capture_ref="ref-1", channel="sms", wording_version="v1", wording_sha256="b" * 64, contact="c", artifact_sha256="a" * 64)
        z = dt.timezone.utc
        a = C.capture_canonical(captured_at=dt.datetime(2026, 11, 1, 12, 0, 0, tzinfo=z), **base)
        self.assertEqual(a, C.capture_canonical(captured_at=dt.datetime(2026, 11, 1, 12, 0, 0, 750000, tzinfo=z), **base))
        self.assertEqual(a, C.capture_canonical(captured_at="2026-11-01T12:00:00.999999Z", **base))
        self.assertEqual(a, C.capture_canonical(captured_at=1793534400.75, **base))
        self.assertNotEqual(a, C.capture_canonical(captured_at=dt.datetime(2026, 11, 1, 11, 59, 59, 999999, tzinfo=z), **base))

    def test_lp(self):
        self.assertEqual(C.lp("ab"), "2:ab"); self.assertEqual(C.lp("é"), "2:é")   # BYTE length, as octet_length in SQL
        self.assertEqual(C.lp(""), "0:")

    def test_a_different_key_gives_a_different_seal(self):
        at = dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc)
        kw = dict(workspace_id="w", capture_ref="ref-1", channel="sms", wording_version="v1", wording_sha256="b" * 64, captured_at=at, contact="c", artifact_sha256="a" * 64)
        self.assertNotEqual(C.capture_seal(K1, **kw), C.capture_seal(K2, **kw))


def key_spec(x):
    """Decode a key_cases.tsv spec (the SQL test decodes the same): \\N, lit:<text>, sha256:<seed>, mix:<seedA>:<seedB>:<n> (n hex chars of A then the rest of B), splice:<seed>:<text> (text written over
    characters 20.. of sha256(seed)), upper:<seed>. Keys are derived at run time so no key-shaped literal sits in the repository."""
    h = lambda t: hashlib.sha256(t.encode()).hexdigest()
    if x == "\\N":
        return None
    kind, _, rest = x.partition(":")
    if kind == "lit":
        return rest
    if kind == "sha256":
        return h(rest)
    if kind == "mix":
        a, b, n = rest.split(":")
        return h(a)[:int(n)] + h(b)[:64 - int(n)]
    if kind == "splice":
        seed, ins = rest.split(":")
        v = h(seed)
        return v[:20] + ins + v[20 + len(ins):]
    if kind == "upper":
        return h(rest).upper()
    raise ValueError(x)


def key_cases():
    out = []
    with open(os.path.join(HERE, "sqltests", "data", "key_cases.tsv"), encoding="utf-8", newline="") as f:
        for line in f:
            v, o, want = line.rstrip("\n").split("\t")
            out.append((key_spec(v), key_spec(o), want))
    return out


class KeyPolicy(unittest.TestCase):
    def test_shared_table_with_the_sql_test(self):
        cases = key_cases()
        self.assertGreater(len(cases), 20)
        for v, o, want in cases:
            self.assertEqual(C.key_problem(v, o) or "ok", want, (v[:20], want))

    def test_identical_and_contained_keys_are_refused(self):
        self.assertEqual(C.key_problem(K1, K1), "related_key")
        self.assertEqual(C.key_problem("Q" + K1, K1), "format")
        self.assertIsNone(C.key_problem(K1, K2))
        self.assertEqual(C.key_problem(None), "missing")

    def test_a_guessable_phrase_is_refused_whatever_its_entropy(self):
        """Re-review item 5: the key fingerprints are HMACs of fixed strings, so only 64 lowercase hex characters (32 random bytes) are accepted."""
        for phrase in ("correct horse battery staple 2024!!", "correct-horse-battery-staple-2024-correct-horse-battery-staple", "Zq8!mK3#vR7$pL2@xN5%tB9^wC4&yH6*jD1-aB3dE5fG7hJ9kL2mN4pQ6rS8tU0vW"):
            self.assertIn(C.key_problem(phrase), ("length", "format"), phrase)
        self.assertEqual(C.key_problem(K1.upper()), "format")
        self.assertIsNone(C.key_problem(K1))

    def test_cli_never_prints_the_key(self):
        import subprocess, sys
        env = {**os.environ, "CONSENT_KEY_CANDIDATE": "abcdefghijklmnopqrstuvwxyz0123456789"}
        r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "hq_consent.py"), "check-key"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1); self.assertIn("REFUSED", r.stdout); self.assertNotIn("abcdefghij", r.stdout + r.stderr)
        r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "hq_consent.py"), "check-key"], env={**env, "CONSENT_KEY_CANDIDATE": K1, "CONSENT_KEY_OTHER": K2}, capture_output=True, text=True)
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "key OK")); self.assertNotIn(K1, r.stdout + r.stderr)


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
