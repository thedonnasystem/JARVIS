"""Sender-side high-water mark (hq_gatemark): a restored database must never be trusted by a sender that remembers more than the database does.
No network: a fake PostgREST and a fake B2 stand in. Nothing here sends anything."""
import json, os, tempfile, unittest
from unittest import mock
import hq, hq_gatemark as G


class FakeDb:
    """What public.ffm_sender_attest / ffm_gate_state answer, modelled on the SQL (the SQL itself is tested in sqltests/consent_restore_gate_check.sql)."""
    def __init__(self, epoch=10, fp="777:1", open_=True, verified_at="2026-11-15T10:00:00+00:00", marker=None):
        self.epoch, self.fp, self.open, self.verified_at, self.marker, self.calls, self.closed = epoch, fp, open_, verified_at, marker, [], False
    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        self.calls.append((path, body))
        if path.endswith("/rpc/ffm_sender_attest"):
            if body["p_hwm_epoch"] is None: return {"ok": False, "reason": "sender_unanchored"}
            if self.epoch < body["p_hwm_epoch"] or (body["p_hwm_instance"] and body["p_hwm_instance"] != self.fp):
                self.closed = True; return {"ok": False, "reason": "rollback_detected", "detail": "x", "epoch": self.epoch}
            return {"ok": True, "epoch": self.epoch, "instance_fp": self.fp, "open": self.open}
        if path.endswith("/rpc/ffm_gate_state"):
            return {"epoch": self.epoch, "instance_fp": self.fp, "open": self.open, "state": "verified", "verified_at": self.verified_at, "last_restore_marker": self.marker}
        if path.endswith("/audit_log"): return None
        raise AssertionError(path)


class T(unittest.TestCase):
    def setUp(self):
        G._CACHE.update(at=0.0, rec=None)
        self.d = tempfile.mkdtemp(); self.f = os.path.join(self.d, "hwm.jsonl")
        self.env = mock.patch.dict(os.environ, {"GATE_HWM_FILE": self.f}, clear=True); self.env.start(); self.addCleanup(self.env.stop)

    def run_with(self, db):
        return mock.patch.object(hq, "_request", db)

    def test_nothing_configured_is_closed(self):
        with mock.patch.dict(os.environ, {}, clear=True), self.run_with(FakeDb()) as rq:
            a = G.attest(); self.assertEqual((a["ok"], a["reason"]), (False, "hwm_unavailable"))

    def test_unanchored_sender_never_asks_the_database_and_never_self_anchors(self):
        db = FakeDb()
        with self.run_with(db):
            a = G.attest()
        self.assertEqual((a["ok"], a["reason"]), (False, "sender_unanchored")); self.assertEqual(db.calls, []); self.assertFalse(os.path.exists(self.f))

    def test_anchor_requires_an_open_gate_verified_after_the_last_restore(self):
        for db, why in ((FakeDb(open_=False), "gate_not_open"), (FakeDb(marker="2026-11-15T11:00:00+00:00"), "verified_before_restore"), (FakeDb(verified_at=None), "gate_not_open")):
            with self.run_with(db):
                r = G.anchor(); self.assertEqual((r["ok"], r["reason"]), (False, why))
            self.assertFalse(os.path.exists(self.f))
        with self.run_with(FakeDb(epoch=10, marker="2026-11-15T09:00:00+00:00")):
            r = G.anchor()
        self.assertEqual((r["ok"], r["epoch"], r["generation"]), (True, 10, 1))

    def test_advances_never_lowers(self):
        with self.run_with(FakeDb(epoch=10)):
            G.anchor()
        with self.run_with(FakeDb(epoch=14)):
            a = G.attest(); self.assertTrue(a["ok"])
        self.assertEqual(G.read_mark()["epoch"], 14)
        db = FakeDb(epoch=9)                                        # the database went BACK (restore): refused, the database closes itself, the mark does not move
        with self.run_with(db):
            a = G.attest()
        self.assertEqual((a["ok"], a["reason"], db.closed), (False, "rollback_detected", True)); self.assertEqual(G.read_mark()["epoch"], 14)
        with open(self.f) as fh: self.assertEqual(len(fh.read().splitlines()), 2)

    def test_instance_change_is_detected(self):
        with self.run_with(FakeDb(epoch=10, fp="777:1")):
            G.anchor()
        db = FakeDb(epoch=50, fp="888:1")                          # a HIGHER epoch on another cluster / timeline is still not our database
        with self.run_with(db):
            a = G.attest()
        self.assertEqual((a["ok"], a["reason"], db.closed), (False, "rollback_detected", True))

    def test_reanchor_after_restore_starts_a_new_generation_and_may_lower_the_epoch(self):
        with self.run_with(FakeDb(epoch=100)):
            G.anchor()
        with self.run_with(FakeDb(epoch=3, marker="2026-11-15T09:00:00+00:00", verified_at="2026-11-15T12:00:00+00:00")):
            r = G.anchor()
            self.assertEqual((r["ok"], r["generation"], r["epoch"]), (True, 2, 3))
            self.assertTrue(G.attest()["ok"])                      # generation 2 outranks generation 1 whatever the epochs are
        self.assertEqual(G.read_mark()["gen"], 2)

    def test_corrupt_or_unwritable_store_fails_closed(self):
        with open(self.f, "w") as fh: fh.write("not json\n")
        with self.run_with(FakeDb()):
            a = G.attest(); self.assertEqual((a["ok"], a["reason"]), (False, "hwm_unavailable"))
            r = G.anchor(); self.assertEqual((r["ok"], r["reason"]), (False, "hwm_unavailable"))
        os.unlink(self.f)
        with self.run_with(FakeDb()), mock.patch.object(G.FileStore, "append", side_effect=OSError("disk full")):
            r = G.anchor(); self.assertFalse(r["ok"])

    def test_database_errors_and_odd_answers_are_a_no(self):
        with self.run_with(FakeDb()):
            G.anchor()
        for reply in (None, "ok", [], {}, {"ok": "true"}, {"ok": 1}):
            with mock.patch.object(hq, "_request", return_value=reply):
                self.assertFalse(G.attest()["ok"], repr(reply))
        with mock.patch.object(hq, "_request", side_effect=RuntimeError("down")):
            self.assertEqual(G.attest()["reason"], "database_unreachable")

    def test_tick_uses_the_cache_a_send_does_not(self):
        with self.run_with(FakeDb(epoch=10)):
            G.anchor()
        reads = []
        orig = G.read_mark
        def spy(force=True):
            reads.append(force); return orig(force)
        with self.run_with(FakeDb(epoch=10)), mock.patch.object(G, "read_mark", spy):
            G.attest(force=False); G.attest()
        self.assertEqual(reads, [False, True])
        # a cached mark is ignored once it is older than CACHE_SECONDS
        G._CACHE["at"] -= G.CACHE_SECONDS + 1
        self.assertEqual(G.read_mark(force=False)["epoch"], 10)

    def test_the_higher_of_two_stores_wins_so_losing_one_does_not_lower_the_mark(self):
        b2 = FakeB2()
        with mock.patch.dict(os.environ, {"GATE_HWM_FILE": self.f, "BACKUP_PUT_URL": "b2://abcdef123456/hq", "BACKUP_AUTH": "id:key"}), mock.patch.object(G, "B2Store", lambda u, a: b2):
            with self.run_with(FakeDb(epoch=20)):
                G.anchor()
            self.assertEqual(len(b2.names), 1); self.assertIn("hwm-000001-000000000020-777_1.json", b2.names[0])
            os.unlink(self.f); G._CACHE.update(at=0.0, rec=None)       # the container disk was wiped by a redeploy: B2 still remembers
            self.assertEqual(G.read_mark()["epoch"], 20)
            db = FakeDb(epoch=7)
            with self.run_with(db):
                self.assertEqual(G.attest()["reason"], "rollback_detected")
            b2.names.clear(); G._CACHE.update(at=0.0, rec=None)          # both gone: UNANCHORED, never "trust whatever the database says"
            self.assertFalse(os.path.exists(self.f))
            with self.run_with(FakeDb(epoch=7)):
                self.assertEqual(G.attest()["reason"], "sender_unanchored")

    def test_b2_store_over_the_wire_format(self):
        """B2Store against a fake of the B2 native API: names carry the mark (no read permission needed), listing is paged, bad names are ignored."""
        import hq_backup as B
        listed = {"files": [{"fileName": "hq/gate/hwm-000001-000000000005-777_1.json"}, {"fileName": "hq/gate/hwm-000002-000000000003-777_2.json"}, {"fileName": "hq/gate/junk.txt"}], "nextFileName": None}
        puts = []
        def call(method, url, headers, body=None, timeout=120):
            if url.endswith("b2_list_file_names"): return 200, json.dumps(listed).encode()
            raise AssertionError(url)
        with mock.patch.object(B, "b2_authorize", return_value=("tok", "https://api.backblazeb2.com")), mock.patch.object(B, "_call", call), \
             mock.patch.object(B, "b2_put", lambda name, data, bucket, prefix, token, api: puts.append((prefix + name, json.loads(data)))):
            s = G.B2Store("b2://abcdef123456/hq", "id:key")
            recs = s.read(); self.assertEqual([(r["gen"], r["epoch"], r["fp"]) for r in recs], [(1, 5, "777:1"), (2, 3, "777:2")])
            s.append({"gen": 3, "epoch": 9, "fp": None})
        self.assertEqual(puts[0][0], "hq/gate/hwm-000003-000000000009-unavailable.json")
        with mock.patch.object(B, "b2_authorize", return_value=("tok", "https://api.backblazeb2.com")), mock.patch.object(B, "_call", lambda *a, **k: (500, b"")):
            with self.assertRaises(G.GateMarkError): G.B2Store("b2://abcdef123456/hq", "id:key").read()


class FakeB2:
    kind = "b2"
    def __init__(self): self.names = []
    def read(self):
        import re
        return [G._rec(int(m.group(1)), int(m.group(2)), G._name_to_fp(m.group(3))) for n in self.names for m in [G.NAME_RE.search(n)] if m]
    def append(self, rec): self.names.append(f"hq/gate/hwm-{rec['gen']:06d}-{rec['epoch']:012d}-{G._fp_to_name(rec['fp'])}.json")


if __name__ == "__main__":
    unittest.main()
