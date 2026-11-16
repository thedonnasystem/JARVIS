"""Oversight ledger: the chain detects edits, deletions and reordering; nobody but an owner key can record an owner decision.
Synthetic entries only. Runs in the existing `scripts-tests` gate step."""
import base64
import contextlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "ops", "oversight"))
import ledger as L  # noqa: E402

SHA = "a" * 40
# `cryptography` is in requirements/dev.lock. It is imported unconditionally: if it were missing, the owner-signature tests must
# fail loudly, not be skipped (a skipped control test is not a passing one).
from cryptography.hazmat.primitives import serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402


def review(i, reviewer="reviewer-b", author="author-a", rec="NEEDS_MORE_WORK", **kw):
    e = {"type": "review", "id": f"R-{i}", "ts": "2026-11-16T00:00:00Z", "subject": {"pr": 1, "sha": SHA}, "reviewer": {"id": reviewer},
         "author": {"id": author}, "recommendation": rec, "findings": [{"id": "F1", "severity": "SHOULD-FIX", "title": "x"}],
         "evidence": [{"ref": "cmd: python3 -m unittest", "sha256": "b" * 64}]}
    e.update(kw)
    return e


def main(argv):
    """ledger.main without its console output (the gate log stays readable)."""
    with open(os.devnull, "w") as null, contextlib.redirect_stdout(null), contextlib.redirect_stderr(null):
        return L.main(argv)


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "ledger", "reviews.jsonl")

    def tearDown(self):
        self.dir.cleanup()

    def fill(self, n=4):
        for i in range(1, n + 1):
            L.append(review(i), self.path, keys={})

    def lines(self):
        with open(self.path) as f:
            return f.read().splitlines()

    def write(self, lines):
        with open(self.path, "w") as f:
            f.write("\n".join(lines) + "\n")

    def errs(self, keys=None):
        return L.verify_file(self.path, keys or {})[1]


class Chain(Base):
    def test_clean_chain_verifies(self):
        self.fill()
        entries, errs = L.verify_file(self.path, {})
        self.assertEqual(errs, [])
        self.assertEqual([e["seq"] for e in entries], [1, 2, 3, 4])
        self.assertEqual(entries[0]["prev_hash"], L.GENESIS)
        self.assertEqual(entries[2]["prev_hash"], entries[1]["entry_hash"])

    def test_edit_detected(self):
        self.fill()
        ls = self.lines()
        e = json.loads(ls[1])
        e["recommendation"] = "APPROVE"
        ls[1] = L.canonical(e)
        self.write(ls)
        self.assertTrue(any("entry_hash does not match" in x for x in self.errs()))

    def test_edit_with_recomputed_hash_breaks_next_link(self):
        self.fill()
        ls = self.lines()
        e = json.loads(ls[1])
        e["recommendation"] = "APPROVE"
        e["entry_hash"] = L.entry_hash(e)
        ls[1] = L.canonical(e)
        self.write(ls)
        self.assertTrue(any("line 3: prev_hash" in x for x in self.errs()))

    def test_deletion_in_the_middle_detected(self):
        self.fill()
        ls = self.lines()
        del ls[1]
        self.write(ls)
        errs = self.errs()
        self.assertTrue(any("seq is 3, expected 2" in x for x in errs))
        self.assertTrue(any("prev_hash" in x for x in errs))

    def test_deletion_of_first_entry_detected(self):
        self.fill()
        self.write(self.lines()[1:])
        self.assertTrue(any("line 1: prev_hash" in x for x in self.errs()))

    def test_reordering_detected(self):
        self.fill()
        ls = self.lines()
        ls[1], ls[2] = ls[2], ls[1]
        self.write(ls)
        self.assertTrue(any("reordered" in x for x in self.errs()))

    def test_inserted_entry_detected(self):
        self.fill(2)
        ls = self.lines()
        forged = review(9)
        forged.update(seq=2, prev_hash=json.loads(ls[0])["entry_hash"])
        forged["entry_hash"] = L.entry_hash(forged)
        self.write([ls[0], L.canonical(forged), ls[1]])
        self.assertTrue(any("line 3" in x for x in self.errs()))

    def test_non_canonical_and_garbage_lines_detected(self):
        self.fill(2)
        ls = self.lines()
        self.write([ls[0], json.dumps(json.loads(ls[1]), indent=None, sort_keys=False, separators=(", ", ": "))])
        self.assertTrue(any("canonical" in x for x in self.errs()))
        self.write([ls[0], "not json"])
        self.assertTrue(any("not valid JSON" in x for x in self.errs()))

    def test_tail_truncation_needs_an_anchor(self):
        """Honest limit: cutting the END leaves a valid chain. The anchor (expected head / git prefix) is what catches it."""
        self.fill()
        full_head = L.head_hash(L.verify_file(self.path, {})[0])
        self.write(self.lines()[:2])
        entries, errs = L.verify_file(self.path, {})
        self.assertEqual(errs, [])
        self.assertNotEqual(L.head_hash(entries), full_head)
        self.assertEqual(main(["verify", "--file", self.path, "--expect-head", full_head]), 1)

    def test_append_refuses_on_broken_ledger(self):
        self.fill(2)
        ls = self.lines()
        self.write([ls[1]])
        with self.assertRaises(ValueError):
            L.append(review(5), self.path, keys={})

    def test_duplicate_id_refused(self):
        self.fill(1)
        with self.assertRaises(ValueError):
            L.append(review(1), self.path, keys={})


class Rules(Base):
    def test_self_review_refused(self):
        with self.assertRaisesRegex(ValueError, "self-review"):
            L.append(review(1, reviewer="same", author="same"), self.path, keys={})

    def test_short_sha_refused(self):
        with self.assertRaisesRegex(ValueError, "40-hex"):
            L.append(review(1, subject={"sha": "abc1234"}), self.path, keys={})

    def test_bad_recommendation_refused(self):
        with self.assertRaises(ValueError):
            L.append(review(1, rec="APPROVED_BY_OWNER"), self.path, keys={})

    def test_review_cannot_carry_owner_decision(self):
        for field in L.OWNER_ONLY_FIELDS:
            with self.assertRaisesRegex(ValueError, "reserved for owner_decision"):
                L.append(review(1, **{field: "approve"}), self.path, keys={})

    def test_import_must_be_marked_not_reverified_with_hashes(self):
        e = review(1, type="import")
        with self.assertRaisesRegex(ValueError, "imported=true"):
            L.append(e, self.path, keys={})
        with self.assertRaises(ValueError):
            L.append(dict(e, imported=True, re_verified=True), self.path, keys={})
        with self.assertRaises(ValueError):
            L.append(dict(e, imported=True, re_verified=False, evidence=[{"ref": "file"}]), self.path, keys={})
        L.append(dict(e, imported=True, re_verified=False), self.path, keys={})
        self.assertEqual(self.errs(), [])

    def test_mechanical_entry(self):
        m = {"type": "mechanical_check", "id": "M-1", "subject": {"sha": SHA}, "reviewer": {"id": "engine"}, "verdict": "REJECT", "evidence": [{"ref": "f", "sha256": "c" * 64}]}
        L.append(m, self.path, keys={})
        with self.assertRaises(ValueError):
            L.append(dict(m, id="M-2", verdict="APPROVED"), self.path, keys={})

    def test_owner_decision_without_registered_key_refused(self):
        self.fill(1)
        od = {"type": "owner_decision", "id": "OD-1", "ts": "2026-11-16T00:00:00Z", "subject": {"pr": 1, "sha": SHA}, "review_id": "R-1", "decision": "approve",
              "review_hash": json.loads(self.lines()[0])["entry_hash"], "releases": [],
              "decision_text": "ok", "key_id": "owner-1", "signature": base64.b64encode(b"x" * 64).decode()}
        with self.assertRaisesRegex(ValueError, "not registered"):
            L.append(od, self.path, keys={})

    def test_repo_owner_keys_are_empty_so_no_owner_decision_can_exist(self):
        self.assertEqual(L.load_owner_keys(), {})

    def test_forged_owner_line_written_by_hand_fails_verify(self):
        self.fill(1)
        od = {"type": "owner_decision", "id": "OD-1", "ts": "2026-11-16T00:00:00Z", "subject": {"sha": SHA}, "review_id": "R-1", "decision": "approve",
              "decision_text": "owner approved", "key_id": "owner-1", "signature": "AAAA", "seq": 2, "prev_hash": json.loads(self.lines()[0])["entry_hash"]}
        od["entry_hash"] = L.entry_hash(od)
        with open(self.path, "a") as f:
            f.write(L.canonical(od) + "\n")
        self.assertTrue(any("not registered" in x for x in self.errs()))


class OwnerSignature(Base):
    def setUp(self):
        super().setUp()
        self.sk = Ed25519PrivateKey.generate()   # generated per test run; never stored
        pub = self.sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.keys = {"owner-test": base64.b64encode(pub).decode()}
        self.r1 = L.append(review(1), self.path, keys=self.keys)

    def od(self, sign=True, sk=None, **kw):
        e = {"type": "owner_decision", "id": "OD-1", "ts": "2026-11-16T01:00:00Z", "subject": {"pr": 1, "sha": SHA}, "review_id": "R-1",
             "review_hash": self.r1["entry_hash"], "decision": "approve", "decision_text": "Approve merge of PR 1 at this SHA.",
             "releases": ["PROTECTED"], "key_id": "owner-test"}
        e.update(kw)
        e["signature"] = base64.b64encode((sk or self.sk).sign(L.owner_payload(e)) if sign else b"\0" * 64).decode()
        return e

    def test_signed_decision_accepted_and_verifies(self):
        L.append(self.od(), self.path, keys=self.keys)
        self.assertEqual(self.errs(self.keys), [])

    def test_bad_signature_refused(self):
        with self.assertRaisesRegex(ValueError, "does not verify"):
            L.append(self.od(sign=False), self.path, keys=self.keys)

    def test_signature_from_another_key_refused(self):
        e = self.od()
        e["signature"] = base64.b64encode(Ed25519PrivateKey.generate().sign(L.owner_payload(e))).decode()
        with self.assertRaisesRegex(ValueError, "does not verify"):
            L.append(e, self.path, keys=self.keys)

    def test_decision_changed_after_signing_fails(self):
        e = self.od(decision="reject")
        e["decision"] = "approve"
        with self.assertRaises(ValueError):
            L.append(e, self.path, keys=self.keys)

    def test_sha_changed_after_signing_fails(self):
        e = self.od()
        e["subject"] = {"pr": 1, "sha": "b" * 40}
        with self.assertRaises(ValueError):
            L.append(e, self.path, keys=self.keys)

    def test_decision_for_unknown_review_refused(self):
        with self.assertRaisesRegex(ValueError, "not earlier in the ledger"):
            L.append(self.od(review_id="R-404"), self.path, keys=self.keys)

    # ---- S2
    def test_unsigned_extra_fields_are_refused(self):
        """Before: only 8 fields were signed and unknown fields were stored next to a valid signature."""
        e = self.od()
        for extra in ({"scope": "AUTHORISES PRODUCTION DEPLOY AND CAP RAISE"}, {"note": "owner also approved PR 99"}):
            with self.assertRaisesRegex(ValueError, "does not verify|not allowed"):
                L.append(dict(e, **extra), self.path, keys=self.keys)
        signed_extra = self.od(scope="everything")                 # even when signed, an unknown field is refused
        with self.assertRaisesRegex(ValueError, "not allowed in an owner decision"):
            L.append(signed_extra, self.path, keys=self.keys)
        self.assertEqual(len(self.lines()), 1)

    def test_every_field_is_inside_the_signature(self):
        base = self.od()
        for k, v in (("id", "OD-2"), ("ts", "2026-11-17T01:00:00Z"), ("decision_text", "Approve everything."), ("releases", ["PROTECTED", "PRODUCTION"]),
                     ("review_id", "R-2"), ("review_hash", "f" * 64), ("subject", {"pr": 2, "sha": SHA}), ("key_id", "other"), ("decision", "reject")):
            with self.assertRaises(ValueError, msg=k):
                L.append(dict(base, **{k: v}), self.path, keys=dict(self.keys, other=self.keys["owner-test"]))
        payload = json.loads(L.owner_payload(base))
        self.assertEqual(set(payload), set(base) - {"signature"})

    def test_decision_is_bound_to_the_review_hash_and_sha(self):
        """Before: the signature bound a review *id string*; replay onto a rewritten ledger with another R-1 verified."""
        good = self.od()
        other = os.path.join(self.dir.name, "other", "reviews.jsonl")
        L.append(review(1, rec="REJECT", subject={"pr": 1, "sha": "b" * 40}), other, keys=self.keys)     # same id, another head, another verdict
        with self.assertRaisesRegex(ValueError, "review_hash is not the entry_hash|subject.sha differs"):
            L.append(good, other, keys=self.keys)
        other2 = os.path.join(self.dir.name, "other2", "reviews.jsonl")
        L.append(review(1, rec="REJECT"), other2, keys=self.keys)                                          # same id and head, different content
        with self.assertRaisesRegex(ValueError, "review_hash is not the entry_hash"):
            L.append(good, other2, keys=self.keys)
        with self.assertRaisesRegex(ValueError, "subject.sha differs"):
            L.append(self.od(subject={"pr": 1, "sha": "b" * 40}), self.path, keys=self.keys)               # signed, but for a head the review is not about
        with self.assertRaisesRegex(ValueError, "must refer to a review"):
            L.append(self.od(), self.path, keys=self.keys) and L.append(self.od(id="OD-2", review_id="OD-1", review_hash=json.loads(self.lines()[-1])["entry_hash"]), self.path, keys=self.keys)

    def test_replay_of_the_same_decision_is_refused(self):
        L.append(self.od(), self.path, keys=self.keys)
        with self.assertRaisesRegex(ValueError, "duplicate id"):
            L.append(self.od(), self.path, keys=self.keys)

    def test_releases_must_be_known_and_only_on_approve(self):
        for kw in ({"releases": ["CI"]}, {"releases": "PROTECTED"}, {"releases": ["PROTECTED", "PROTECTED"]}, {"decision": "reject", "releases": ["PROTECTED"]}):
            with self.assertRaises(ValueError, msg=kw):
                L.append(self.od(**kw), self.path, keys=self.keys)
        L.append(self.od(decision="reject", releases=[]), self.path, keys=self.keys)

    def test_signature_encoding_is_strict(self):
        e = self.od()
        for sig in (e["signature"] + "\n", e["signature"][:-2] + "!!", " " + e["signature"], e["signature"] + "AAAA"):
            with self.assertRaises(ValueError, msg=repr(sig)):
                L.append(dict(e, signature=sig), self.path, keys=self.keys)

    def test_revoked_key_still_verifies_the_past_but_signs_nothing_new(self):
        """Before: removing a key made every past decision fail and bricked the ledger. Now: revoke, never remove."""
        L.append(self.od(), self.path, keys=self.keys)                                     # seq 2, signed while the key was good
        revoked = {"owner-test": {"pub": self.keys["owner-test"], "revoked_after_seq": 2}}
        self.assertEqual(self.errs(revoked), [], "the past decision still verifies")
        L.append(review(3), self.path, keys=revoked)                                       # the ledger still accepts ordinary entries
        r3 = json.loads(self.lines()[-1])
        late = self.od(id="OD-late", review_id="R-3", review_hash=r3["entry_hash"], ts="2026-11-10T00:00:00Z")     # back-dated ts does not help
        with self.assertRaisesRegex(ValueError, "revoked after seq 2"):
            L.append(late, self.path, keys=revoked)
        self.assertTrue(any("revoked" in x for x in self.errs({"owner-test": {"pub": self.keys["owner-test"], "revoked_after_seq": 1}})))
        new_sk = Ed25519PrivateKey.generate()
        both = dict(revoked, **{"owner-2": {"pub": base64.b64encode(new_sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode(), "revoked_after_seq": None}})
        L.append(self.od(id="OD-new", review_id="R-3", review_hash=r3["entry_hash"], key_id="owner-2", sk=new_sk), self.path, keys=both)
        self.assertEqual(self.errs(both), [])

    def test_owner_keys_file_format(self):
        ok = json.dumps({"keys": [{"key_id": "a", "ed25519_public_b64": "x"}, {"key_id": "b", "ed25519_public_b64": "y", "revoked_after_seq": 7}]})
        self.assertEqual(L.parse_owner_keys(ok), {"a": {"pub": "x", "revoked_after_seq": None}, "b": {"pub": "y", "revoked_after_seq": 7}})
        for bad in ("", "[]", "{not json", json.dumps({"keys": [{"key_id": "a"}]}), json.dumps({"keys": [{"key_id": ["a"], "ed25519_public_b64": "x"}]}),
                    json.dumps({"keys": [{"key_id": "a", "ed25519_public_b64": "x"}, {"key_id": "a", "ed25519_public_b64": "y"}]}),
                    json.dumps({"keys": [{"key_id": "a", "ed25519_public_b64": "x", "revoked_after_seq": "soon"}]})):
            self.assertEqual(L.parse_owner_keys(bad), {}, bad)

    def test_owner_payload_command_binds_hash_and_sha(self):
        self.assertEqual(main(["owner-payload", "--file", self.path, "--review-id", "R-1", "--decision", "approve", "--text", "x", "--sha", "b" * 40, "--key-id", "k"]), 1)
        self.assertEqual(main(["owner-payload", "--file", self.path, "--review-id", "R-9", "--decision", "approve", "--text", "x", "--sha", SHA, "--key-id", "k"]), 1)
        out = subprocess.run([sys.executable, os.path.join(ROOT, "ops", "oversight", "ledger.py"), "owner-payload", "--file", self.path, "--review-id", "R-1", "--decision", "approve",
                              "--text", "ok", "--sha", SHA, "--key-id", "owner-test", "--releases", "PROTECTED", "--ts", "2026-11-16T01:00:00Z"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        j = json.loads(out.stdout)
        e = j["entry_without_signature"]
        self.assertEqual((e["review_hash"], e["releases"]), (self.r1["entry_hash"], ["PROTECTED"]))
        e["signature"] = base64.b64encode(self.sk.sign(base64.b64decode(j["payload_to_sign_b64"]))).decode()
        L.append(e, self.path, keys=self.keys)
        self.assertEqual(self.errs(self.keys), [])

    def test_key_removed_later_makes_decision_fail_verify(self):
        L.append(self.od(), self.path, keys=self.keys)
        self.assertTrue(any("not registered" in x for x in self.errs({})))


class Robustness(Base):
    """S3: ordinary input must not brick the ledger."""

    def test_line_separator_characters_in_text_do_not_break_the_file(self):
        """Before: U+2028 / U+2029 / U+0085 were written raw, splitlines() cut the entry in two and every later append was refused."""
        for i, ch in enumerate(("\u2028", "\u2029", "\u0085", "\x0c", "\x1e", "caf\u00e9 \U0001f600"), 1):
            L.append(review(i, findings=[{"id": "F1", "title": "pasted" + ch + "text"}]), self.path, keys={})
            self.assertEqual(self.errs(), [], repr(ch))
        with open(self.path, "rb") as f:
            raw = f.read()
        self.assertTrue(all(b < 128 for b in raw), "the file is pure ASCII")
        self.assertEqual(raw.count(b"\n"), 6)
        self.assertEqual(json.loads(self.lines()[0])["findings"][0]["title"], "pasted\u2028text")

    def test_non_string_ids_are_refused_not_crashed_on(self):
        """Before: accepted on append, TypeError traceback on the next verify."""
        for bad in (review(1, id=["x"]), review(1, id={"a": 1}), review(1, id=7), review(1, id=""), review(1, id=None), dict(review(1), reviewer={"id": ["r"]}),
                    dict(review(1), author={"id": {"a": 1}}), dict(review(1), reviewer="rev"), review(1, ts=5), review(1, ts="yesterday"), review(1, subject=["x"]),
                    review(1, evidence="none"), review(1, evidence=[{"ref": "f", "sha256": "z" * 64}]), review(1, evidence=[{"ref": "f", "sha256": "ab"}])):
            with self.assertRaises(ValueError, msg=repr(bad)[:80]):
                L.append(bad, self.path, keys={})
        self.assertFalse(os.path.exists(self.path) and self.lines())
        for junk in ([1, 2], "x", None):
            with self.assertRaises(ValueError):
                L.append(junk, self.path, keys={})

    def test_hand_written_line_with_bad_types_is_an_error_not_a_traceback(self):
        self.fill(1)
        prev = json.loads(self.lines()[0])["entry_hash"]
        for bad in ({"id": ["x"]}, {"key_id": ["k"], "type": "owner_decision"}, {"type": ["review"]}, {"seq": True}):
            e = dict(review(2), prev_hash=prev, **dict({"seq": 2}, **bad))
            e["entry_hash"] = L.entry_hash(e)
            self.write([self.lines()[0], L.canonical(e)])
            errs = self.errs()
            self.assertTrue(errs, bad)
            self.assertEqual(main(["verify", "--file", self.path]), 1)

    def test_self_review_by_label_variant_is_refused(self):
        with self.assertRaisesRegex(ValueError, "self-review"):
            L.append(review(1, reviewer="Auth ", author="auth"), self.path, keys={})

    def test_bare_file_name_works(self):
        """N6. Before: os.makedirs('') crashed."""
        cwd = os.getcwd()
        os.chdir(self.dir.name)
        try:
            L.append(review(1), "bare.jsonl", keys={})
            self.assertEqual(L.verify_file("bare.jsonl", {})[1], [])
        finally:
            os.chdir(cwd)

    def test_concurrent_appenders_do_not_corrupt_the_chain(self):
        """Before: three concurrent appenders produced duplicate seq values and the ledger was refused from then on."""
        os.makedirs(os.path.dirname(self.path))
        code = ("import sys, json; sys.path.insert(0, sys.argv[1]); import ledger as L\n"
                "for i in range(6):\n"
                "    L.append({'type': 'mechanical_check', 'id': sys.argv[3] + '-' + str(i), 'subject': {'sha': 'a' * 40}, 'reviewer': {'id': 'engine'},\n"
                "              'verdict': 'REJECT', 'evidence': []}, sys.argv[2], keys={})\n")
        procs = [subprocess.Popen([sys.executable, "-c", code, os.path.join(ROOT, "ops", "oversight"), self.path, f"W{n}"], stderr=subprocess.PIPE) for n in range(4)]
        for p in procs:
            _, err = p.communicate(timeout=300)
            self.assertEqual(p.returncode, 0, err.decode()[-400:])
        entries, errs = L.verify_file(self.path, {})
        self.assertEqual(errs, [])
        self.assertEqual([e["seq"] for e in entries], list(range(1, 25)))
        self.assertEqual(len({e["id"] for e in entries}), 24)

    def test_refused_append_leaves_the_file_byte_identical(self):
        self.fill(2)
        with open(self.path, "rb") as f:
            before = f.read()
        for bad in (review(2), review(3, rec="MAYBE"), review(3, reviewer="x", author="x")):
            with self.assertRaises(ValueError):
                L.append(bad, self.path, keys={})
        with open(self.path, "rb") as f:
            self.assertEqual(f.read(), before)

    def test_base_file_prefix_check(self):
        """S8: what the workflow proposal runs: the PR's ledger must extend the trusted copy."""
        self.fill(2)
        anchor = os.path.join(self.dir.name, "anchor.jsonl")
        with open(self.path) as f, open(anchor, "w") as g:
            g.write(f.read())
        L.append(review(3), self.path, keys={})
        self.assertEqual(main(["verify", "--file", self.path, "--base-file", anchor, "--owner-keys", os.devnull]), 0)
        self.write(self.lines()[:1])                                   # tail cut: still a valid chain, caught only by the anchor
        self.assertEqual(main(["verify", "--file", self.path, "--owner-keys", os.devnull]), 0)
        self.assertEqual(main(["verify", "--file", self.path, "--base-file", anchor, "--owner-keys", os.devnull]), 1)
        self.assertEqual(main(["verify", "--file", self.path, "--base-file", os.path.join(self.dir.name, "missing"), "--owner-keys", os.devnull]), 1)

    def test_continuation_entry_for_the_documented_repair(self):
        """Repair without rewriting history (RUNBOOK section 7): the broken file is sealed byte-for-byte and a new file starts by naming it."""
        cont = {"type": "continuation", "id": "CONT-1", "ts": "2026-11-16T00:00:00Z", "sealed_file": "ops/oversight/ledger/sealed/reviews-20261116.jsonl",
                "sealed_sha256": "c" * 64, "reason": "line 9 was edited by hand; owner decision recorded in chat 2026-11-16"}
        L.append(cont, self.path, keys={})
        L.append(review(1), self.path, keys={})
        self.assertEqual(self.errs(), [])
        with self.assertRaisesRegex(ValueError, "first line"):
            L.append(dict(cont, id="CONT-2"), self.path, keys={})
        for bad in (dict(cont, sealed_sha256="short"), dict(cont, reason=""), dict(cont, decision="approve")):
            with self.assertRaises(ValueError):
                L.append(bad, os.path.join(self.dir.name, "n", "x.jsonl"), keys={})


class RepoLedger(unittest.TestCase):
    def test_repo_ledger_verifies(self):
        entries, errs = L.verify_file(L.LEDGER)
        self.assertEqual(errs, [])
        self.assertTrue(entries, "the backfilled ledger must not be empty")

    def test_repo_ledger_is_ascii_so_the_canonical_form_did_not_change(self):
        with open(L.LEDGER, "rb") as f:
            self.assertTrue(all(b < 128 for b in f.read()))

    def test_repo_ledger_has_no_owner_decision_and_imports_are_marked(self):
        entries, _ = L.verify_file(L.LEDGER)
        self.assertFalse([e for e in entries if e["type"] == "owner_decision"])
        for e in entries:
            if e["type"] == "import":
                self.assertTrue(e["imported"] and e["re_verified"] is False)


class SqlMirrorProposal(unittest.TestCase):
    """S9: the SQL proposal as text. It has never run on a database; these tests check only what can be checked without one."""

    def setUp(self):
        d = os.path.join(ROOT, "docs", "oversight", "proposals")
        name = [n for n in os.listdir(d) if n.endswith(".sql.txt")]
        self.assertEqual(name, ["YYYYMMDD_oversight_review_ledger_v1.sql.txt"], "placeholder prefix: no date is reserved by a proposal")
        with open(os.path.join(d, name[0])) as f:
            self.sql = f.read()

    def test_owner_field_block_list_equals_ledger_py(self):
        import re
        m = re.search(r"e \?\| array\[([^\]]*)\]", self.sql)
        self.assertEqual(sorted(re.findall(r"'([a-z_]+)'", m.group(1))), sorted(L.OWNER_ONLY_FIELDS))

    def test_entry_types_equal_ledger_py(self):
        import re
        m = re.search(r"entry_type in \(([^)]*)\)", self.sql)
        self.assertEqual(sorted(re.findall(r"'([a-z_]+)'", m.group(1))), sorted(L.TYPES))

    def test_hash_is_recomputed_and_owner_path_is_bound(self):
        code = "\n".join(l.split("--")[0] for l in self.sql.splitlines())
        self.assertEqual(code.count(":= public.oversight_line_hash(p_line)"), 2, "both writers recompute the hash from the line")
        self.assertIn("new.entry_hash is distinct from public.oversight_line_hash(new.line)", code, "and so does the insert trigger")
        for needle in ("sha256(convert_to(", "review_hash", "r.subject_sha is distinct from", "perform public.ffm_require_owner()"):
            self.assertIn(needle, code, needle)
        self.assertNotIn("p_entry", code, "writers take the exact line, not a JSON value that would have to be re-serialised")

    def test_the_cut_the_sql_makes_reproduces_entry_hash_on_real_lines(self):
        """Python mirror of oversight_line_hash: remove the `"entry_hash":"<hex>"` member and its comma from the stored line."""
        import hashlib

        def line_hash(line):
            h = json.loads(line)["entry_hash"]
            member = '"entry_hash":"' + h + '"'
            pos = line.find(member + ",")
            if pos < 0:
                pos = line.find("," + member)
            pre = line[:pos] + line[pos + len(member) + 1:]
            return hashlib.sha256(pre.encode("ascii")).hexdigest(), h

        with open(L.LEDGER) as f:
            lines = f.read().split("\n")[:-1]
        e = {"type": "mechanical_check", "id": "a", "ts": "2026-11-16T00:00:00Z", "subject": {"sha": SHA}, "reviewer": {"id": "x"}, "verdict": "REJECT", "evidence": [],
             "seq": 1, "prev_hash": L.GENESIS}
        first = {"a": 1, "entry_hash": None}                         # entry_hash as the LAST key (no key sorts after it)
        first["entry_hash"] = L.entry_hash(first)
        e["entry_hash"] = L.entry_hash(e)
        nested = dict(e, evidence=[{"ref": "r", "entry_hash": "0" * 64}])
        nested["entry_hash"] = L.entry_hash(nested)
        for line in lines + [L.canonical(e), L.canonical(first), L.canonical(nested)]:
            got, want = line_hash(line)
            self.assertEqual(got, want, line[:80])


if __name__ == "__main__":
    unittest.main()
