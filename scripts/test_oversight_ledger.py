"""Oversight ledger: the chain detects edits, deletions and reordering; nobody but an owner key can record an owner decision.
Synthetic entries only. Runs in the existing `scripts-tests` gate step."""
import base64
import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "ops", "oversight"))
import ledger as L  # noqa: E402

SHA = "a" * 40
try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    HAVE_CRYPTO = True
except ImportError:  # pragma: no cover
    HAVE_CRYPTO = False


def review(i, reviewer="reviewer-b", author="author-a", rec="NEEDS_MORE_WORK", **kw):
    e = {"type": "review", "id": f"R-{i}", "ts": "2026-11-16T00:00:00Z", "subject": {"pr": 1, "sha": SHA}, "reviewer": {"id": reviewer},
         "author": {"id": author}, "recommendation": rec, "findings": [{"id": "F1", "severity": "SHOULD-FIX", "title": "x"}],
         "evidence": [{"ref": "cmd: python3 -m unittest", "sha256": "b" * 64}]}
    e.update(kw)
    return e


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
        self.assertEqual(L.main(["verify", "--file", self.path, "--expect-head", full_head]), 1)

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
        for field in ("owner_decision", "owner_approved", "decision", "signature"):
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
        od = {"type": "owner_decision", "id": "OD-1", "ts": "2026-11-16T00:00:00Z", "subject": {"sha": SHA}, "review_id": "R-1", "decision": "approve",
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


@unittest.skipUnless(HAVE_CRYPTO, "cryptography not installed")
class OwnerSignature(Base):
    def setUp(self):
        super().setUp()
        self.sk = Ed25519PrivateKey.generate()   # generated per test run; never stored
        pub = self.sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.keys = {"owner-test": base64.b64encode(pub).decode()}
        L.append(review(1), self.path, keys=self.keys)

    def od(self, sign=True, **kw):
        e = {"type": "owner_decision", "id": "OD-1", "ts": "2026-11-16T01:00:00Z", "subject": {"pr": 1, "sha": SHA}, "review_id": "R-1",
             "decision": "approve", "decision_text": "Approve merge of PR 1 at this SHA.", "key_id": "owner-test"}
        e.update(kw)
        e["signature"] = base64.b64encode(self.sk.sign(L.owner_payload(e)) if sign else b"\0" * 64).decode()
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
        with self.assertRaisesRegex(ValueError, "not in the ledger"):
            L.append(self.od(review_id="R-404"), self.path, keys=self.keys)

    def test_key_removed_later_makes_decision_fail_verify(self):
        L.append(self.od(), self.path, keys=self.keys)
        self.assertTrue(any("not registered" in x for x in self.errs({})))


class RepoLedger(unittest.TestCase):
    def test_repo_ledger_verifies(self):
        entries, errs = L.verify_file(L.LEDGER)
        self.assertEqual(errs, [])
        self.assertTrue(entries, "the backfilled ledger must not be empty")

    def test_repo_ledger_has_no_owner_decision_and_imports_are_marked(self):
        entries, _ = L.verify_file(L.LEDGER)
        self.assertFalse([e for e in entries if e["type"] == "owner_decision"])
        for e in entries:
            if e["type"] == "import":
                self.assertTrue(e["imported"] and e["re_verified"] is False)


if __name__ == "__main__":
    unittest.main()
