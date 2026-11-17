"""Sender-side high-water mark (hq_gatemark): a restored database must never be trusted by a sender that remembers more than the database does.
No network: a fake PostgREST and a fake B2 stand in. Nothing here sends anything."""
import json, os, tempfile, unittest
from unittest import mock
import hq, hq_gatemark as G


class FakeDb:
    """What public.ffm_sender_attest / ffm_gate_state answer, modelled on the SQL (the SQL itself is tested in sqltests/consent_restore_gate_check.sql)."""
    def __init__(self, epoch=10, fp="777:1", open_=True, core_ok=True, owner_marker=0, mark_gen=0):
        self.epoch, self.fp, self.open, self.core_ok, self.owner_marker, self.mark_gen, self.calls, self.closed = epoch, fp, open_, core_ok, owner_marker, mark_gen, [], False
    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        self.calls.append((path, body))
        if path.endswith("/rpc/ffm_sender_attest"):
            if body["p_hwm_epoch"] is None: return {"ok": False, "reason": "sender_unanchored"}
            if self.epoch < body["p_hwm_epoch"] or (body["p_hwm_instance"] and body["p_hwm_instance"] != self.fp):
                self.closed = True; return {"ok": False, "reason": "rollback_detected", "detail": "x", "epoch": self.epoch}
            if body["p_hwm_gen"] > self.mark_gen:
                if not self.core_ok: return {"ok": False, "reason": "anchor_refused", "detail": "not verified"}
                if body["p_hwm_epoch"] != self.epoch: return {"ok": False, "reason": "anchor_refused", "detail": "an anchor must carry exactly the current database epoch (%d)" % self.epoch}
                self.mark_gen = body["p_hwm_gen"]
            return {"ok": True, "epoch": self.epoch, "instance_fp": self.fp, "open": self.open}
        if path.endswith("/rpc/ffm_gate_state"):
            return {"epoch": self.epoch, "instance_fp": self.fp, "open": self.open, "core_ok": self.core_ok, "state": "verified", "last_marker_id": self.owner_marker,
                    "last_owner_marker_id": self.owner_marker, "mark_gen": self.mark_gen}
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
        with mock.patch.dict(os.environ, {}, clear=True), self.run_with(FakeDb()):
            a = G.attest(); self.assertEqual((a["ok"], a["reason"]), (False, "hwm_unavailable"))

    def test_unanchored_sender_never_asks_the_database_and_never_self_anchors(self):
        db = FakeDb()
        with self.run_with(db):
            a = G.attest()
        self.assertEqual((a["ok"], a["reason"]), (False, "sender_unanchored")); self.assertEqual(db.calls, []); self.assertFalse(os.path.exists(self.f))

    def test_anchor_requires_a_freshly_verified_gate(self):
        with self.run_with(FakeDb(core_ok=False)):
            r = G.anchor(); self.assertEqual((r["ok"], r["reason"]), (False, "gate_not_verified"))
        self.assertFalse(os.path.exists(self.f))
        with self.run_with(FakeDb(epoch=10)):
            r = G.anchor()
        self.assertEqual((r["ok"], r["epoch"], r["generation"]), (True, 10, 1))

    def test_advances_never_lowers(self):
        with self.run_with(FakeDb(epoch=10)):
            G.anchor()
        with self.run_with(FakeDb(epoch=14, mark_gen=1)):
            a = G.attest(); self.assertTrue(a["ok"])
        self.assertEqual(G.read_mark()["epoch"], 14)
        db = FakeDb(epoch=9, mark_gen=1)                            # the database went BACK (restore): refused, the database closes itself, the mark does not move
        with self.run_with(db):
            a = G.attest()
        self.assertEqual((a["ok"], a["reason"], db.closed), (False, "rollback_detected", True)); self.assertEqual(G.read_mark()["epoch"], 14)
        with open(self.f) as fh: self.assertEqual(len(fh.read().splitlines()), 2)

    def test_instance_change_is_detected(self):
        with self.run_with(FakeDb(epoch=10, fp="777:1")):
            G.anchor()
        db = FakeDb(epoch=50, fp="888:1", mark_gen=1)              # a HIGHER epoch on another cluster / timeline is still not our database
        with self.run_with(db):
            a = G.attest()
        self.assertEqual((a["ok"], a["reason"], db.closed), (False, "rollback_detected", True))

    def test_the_exact_pitr_scenario_anchor_cannot_lower_the_mark_without_an_owner_restore(self):
        """A provider restore the sender did not see (no attest in between): the database epoch is BELOW the mark, the gate was re-verified by the owner, but NO owner restore was recorded."""
        with self.run_with(FakeDb(epoch=100)):
            G.anchor()
        before = G.read_mark()
        db = FakeDb(epoch=40, mark_gen=1, owner_marker=0)          # restored copy: epoch 40 < 100, verified (core_ok), no owner marker
        with self.run_with(db):
            r = G.anchor()
        self.assertEqual((r["ok"], r["reason"]), (False, "restore_not_recorded")); self.assertEqual(G.read_mark(), before)
        self.assertIn("ffm_owner_record_restore", r["detail"]); self.assertEqual([c for c in db.calls if c[0].endswith("ffm_sender_attest")], [])   # the database was not even asked
        # an owner marker that this mark ALREADY consumed does not count either
        with self.run_with(FakeDb(epoch=100)): pass
        G.write_mark(G._rec(1, 100, "777:1", om=7))
        with self.run_with(FakeDb(epoch=40, mark_gen=1, owner_marker=7)):
            self.assertEqual(G.anchor()["reason"], "restore_not_recorded")
        # record -> verify -> anchor, in that order: now it is allowed, a NEW generation, and the consumed marker id is stored
        with self.run_with(FakeDb(epoch=40, mark_gen=1, owner_marker=8)):
            r = G.anchor()
        self.assertEqual((r["ok"], r["generation"], r["epoch"]), (True, 2, 40)); m = G.read_mark(); self.assertEqual((m["gen"], m["epoch"], m["om"]), (2, 40, 8))
        with self.run_with(FakeDb(epoch=40, mark_gen=2, owner_marker=8)):
            self.assertTrue(G.attest()["ok"])                      # generation 2 outranks generation 1 whatever the epochs are
        # and a verification that is not fresh (core not ok) is refused even with the owner marker
        with self.run_with(FakeDb(epoch=10, mark_gen=2, owner_marker=9, core_ok=False)):
            self.assertEqual(G.anchor()["reason"], "gate_not_verified")

    def test_anchor_retries_when_the_epoch_moves_between_read_and_call(self):
        db = FakeDb(epoch=10)
        orig = db.__call__
        state = {"n": 0}
        def moving(method, path, body=None, timeout=30, prefer=None):
            if path.endswith("/rpc/ffm_gate_state"):
                r = orig(method, path, body, timeout, prefer)
                if state["n"] == 0: db.epoch += 1             # a write lands right after the sender read the state
                state["n"] += 1
                return r
            return orig(method, path, body, timeout, prefer)
        with mock.patch.object(hq, "_request", moving):
            r = G.anchor()
        self.assertEqual((r["ok"], r["epoch"]), (True, 11))

    def test_next_step_is_ordered(self):
        m = {"gen": 1, "epoch": 100, "om": 5}
        self.assertIn("configure a mark store", G.next_step({"epoch": 1}, None, stores_ok=False))
        self.assertIn("apply the migrations", G.next_step(None, None))
        s = G.next_step({"epoch": 40, "core_ok": True, "last_owner_marker_id": 5}, m)           # rolled back, no new owner marker: step 1 first
        self.assertTrue(s.index("Step 1") < s.index("step 2") < s.index("step 3") and "ffm_owner_record_restore" in s)
        self.assertIn("verify the suppression list", G.next_step({"epoch": 40, "core_ok": False, "last_owner_marker_id": 6}, m))
        self.assertEqual(G.next_step({"epoch": 40, "core_ok": True, "last_owner_marker_id": 6}, m), "/gate anchor")
        self.assertEqual(G.next_step({"epoch": 100, "core_ok": True, "open": True}, m), "none")
        self.assertEqual(G.next_step({"epoch": 100, "core_ok": True, "open": False}, m)[:5], "none:")
        self.assertIn("/gate anchor", G.next_step({"epoch": 1, "core_ok": True}, None))
        with self.run_with(FakeDb(epoch=40, mark_gen=1, owner_marker=5)):
            G.write_mark(G._rec(1, 100, "777:1", om=5)); text = "\n".join(G.status_lines())
        self.assertIn("NEXT STEP:", text); self.assertIn("ffm_owner_record_restore", text)

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

    def test_transient_unreadable_instance_writes_nothing_and_asks_for_nothing(self):
        with self.run_with(FakeDb()):
            G.anchor()
        n = len(open(self.f).read().splitlines())
        with mock.patch.object(hq, "_request", return_value={"ok": False, "reason": "instance_unreadable"}):
            a = G.attest()
        self.assertEqual((a["ok"], a["reason"]), (False, "instance_unreadable")); self.assertEqual(len(open(self.f).read().splitlines()), n)

    def test_tick_uses_the_cache_a_send_does_not(self):
        with self.run_with(FakeDb(epoch=10)):
            G.anchor()
        reads = []
        orig = G.read_mark
        def spy(force=True):
            reads.append(force); return orig(force)
        with self.run_with(FakeDb(epoch=10, mark_gen=1)), mock.patch.object(G, "read_mark", spy):
            G.attest(force=False); G.attest()
        self.assertEqual(reads, [False, True])
        G._CACHE["at"] -= G.CACHE_SECONDS + 1                       # a cached mark is ignored once it is older than CACHE_SECONDS
        self.assertEqual(G.read_mark(force=False)["epoch"], 10)

    def test_the_higher_of_two_stores_wins_so_losing_one_does_not_lower_the_mark(self):
        b2 = FakeB2()
        with mock.patch.dict(os.environ, {"GATE_HWM_FILE": self.f, "BACKUP_PUT_URL": "b2://abcdef123456/hq", "BACKUP_AUTH": "id:key"}), mock.patch.object(G, "B2Store", lambda u, a: b2):
            with self.run_with(FakeDb(epoch=20)):
                G.anchor()
            self.assertEqual(len(b2.names), 1); self.assertIn("hwm-000001-000000000020-000000000-777_1.json", b2.names[0])
            os.unlink(self.f); G._CACHE.update(at=0.0, rec=None)       # the container disk was wiped by a redeploy: B2 still remembers
            self.assertEqual(G.read_mark()["epoch"], 20)
            db = FakeDb(epoch=7, mark_gen=1)
            with self.run_with(db):
                self.assertEqual(G.attest()["reason"], "rollback_detected")
            b2.names.clear(); G._CACHE.update(at=0.0, rec=None)          # both gone: UNANCHORED, never "trust whatever the database says"
            self.assertFalse(os.path.exists(self.f))
            with self.run_with(FakeDb(epoch=7)):
                self.assertEqual(G.attest()["reason"], "sender_unanchored")

    def _b2(self, files, pages=None):
        import hq_backup as B
        calls = []
        def call(method, url, headers, body=None, timeout=120):
            calls.append((url.rsplit("/", 1)[-1], json.loads(body) if body else None))
            if url.endswith("b2_list_file_versions"):
                pg = (pages or [{"files": files, "nextFileName": None, "nextFileId": None}])
                return 200, json.dumps(pg[min(len([c for c in calls if c[0] == "b2_list_file_versions"]) - 1, len(pg) - 1)]).encode()
            raise AssertionError(url)
        return calls, mock.patch.object(B, "b2_authorize", return_value=("tok", "https://api.backblazeb2.com")), mock.patch.object(B, "_call", call)

    def test_b2_store_reads_versions_counts_hides_and_matches_names_strictly(self):
        """b2_list_file_versions (not _names): a HIDDEN mark still counts; hide markers are counted and shown; anything but an exact <prefix>gate/hwm-... name is ignored."""
        P = "hq/gate/"
        files = [{"fileName": P + "hwm-000001-000000000005-000000000-777_1.json", "action": "upload"},
                 {"fileName": P + "hwm-000002-000000000003-000000004-777_2.json", "action": "upload"},
                 {"fileName": P + "hwm-000002-000000000003-000000004-777_2.json", "action": "hide"},             # hiding does not remove the upload version
                 {"fileName": P + "junk.txt", "action": "upload"},
                 {"fileName": P + "sub/hwm-000009-000000000009-000000000-777_1.json", "action": "upload"},      # nested path
                 {"fileName": "evil/hq/gate/hwm-000009-000000000009-000000000-777_1.json", "action": "upload"},   # another prefix that merely CONTAINS ours
                 {"fileName": P + "hwm-000009-000000000009-000000000-777_1.json.bak", "action": "upload"},        # suffix games (search() would have accepted)
                 {"fileName": P + "xhwm-000009-000000000009-000000000-777_1.json", "action": "upload"},
                 {"fileName": P + "hwm-000009-00000000009-000000000-777_1.json", "action": "upload"},             # wrong digit count
                 {"fileName": P + "hwm-000001-000000000005-000000000-777_1.json", "action": "start"}]
        calls, a, c = self._b2(files)
        with a, c:
            s = G.B2Store("b2://abcdef123456/hq", "id:key"); recs = s.read()
        self.assertEqual([(r["gen"], r["epoch"], r["om"], r["fp"]) for r in recs], [(1, 5, 0, "777:1"), (2, 3, 4, "777:2")])
        self.assertEqual((s.hides, s.foreign), (1, 6)); self.assertEqual({c_[0] for c_ in calls}, {"b2_list_file_versions"})
        self.assertEqual(calls[0][1]["prefix"], P)

    def test_fingerprint_with_database_and_table_oids_round_trips_through_the_file_name(self):
        fp = "7708539452488523814:1:16384:24577"      # system_identifier:timeline:database oid:gate table oid
        self.assertEqual(G._name_to_fp(G._fp_to_name(fp)), fp)
        name = f"hwm-000001-000000000005-000000000-{G._fp_to_name(fp)}.json"
        m = G.NAME_RE.fullmatch(name); self.assertTrue(m); self.assertEqual(G._name_to_fp(m.group(4)), fp)
        for bad in ("7_1_2_3_4", "a_1", "1", "1__2"):
            self.assertIsNone(G.NAME_RE.fullmatch(f"hwm-000001-000000000005-000000000-{bad}.json"), bad)

    def test_b2_store_pages_with_start_file_id_and_appends_the_documented_name(self):
        import hq_backup as B
        P = "hq/gate/"
        pages = [{"files": [{"fileName": P + "hwm-000001-000000000005-000000000-777_1.json", "action": "upload"}], "nextFileName": "n1", "nextFileId": "id1"},
                 {"files": [{"fileName": P + "hwm-000001-000000000006-000000000-777_1.json", "action": "upload"}], "nextFileName": None, "nextFileId": None}]
        calls, a, c = self._b2(None, pages)
        puts = []
        with a, c, mock.patch.object(B, "b2_put", lambda name, data, bucket, prefix, token, api: puts.append((prefix + name, json.loads(data)))):
            s = G.B2Store("b2://abcdef123456/hq", "id:key"); self.assertEqual([r["epoch"] for r in s.read()], [5, 6])
            s.append({"gen": 3, "epoch": 9, "fp": None, "om": 12})
        self.assertEqual((calls[1][1]["startFileName"], calls[1][1]["startFileId"]), ("n1", "id1"))
        self.assertEqual(puts[0][0], P + "hwm-000003-000000000009-000000012-unavailable.json")
        with mock.patch.object(B, "b2_authorize", return_value=("tok", "https://api.backblazeb2.com")), mock.patch.object(B, "_call", lambda *a, **k: (500, b"")):
            with self.assertRaises(G.GateMarkError): G.B2Store("b2://abcdef123456/hq", "id:key").read()

    def test_a_hidden_top_mark_cannot_lower_the_effective_mark(self):
        P = "hq/gate/"
        files = [{"fileName": P + "hwm-000001-000000000005-000000000-777_1.json", "action": "upload"},
                 {"fileName": P + "hwm-000001-000000000500-000000000-777_1.json", "action": "hide"},
                 {"fileName": P + "hwm-000001-000000000500-000000000-777_1.json", "action": "upload"}]
        calls, a, c = self._b2(files)
        with a, c:
            st = G.B2Store("b2://abcdef123456/hq", "id:key")
            with mock.patch.object(G, "stores", lambda: [st]):
                self.assertEqual(G.read_mark()["epoch"], 500)
                with mock.patch.object(hq, "_request", FakeDb()):
                    self.assertTrue(any("1 hide marker" in line for line in G.status_lines()))


class FakeB2:
    kind = "b2"
    hides = 0; foreign = 0
    def __init__(self): self.names = []
    def read(self):
        import re
        return [G._rec(int(m.group(1)), int(m.group(2)), G._name_to_fp(m.group(4)), int(m.group(3))) for n in self.names for m in [G.NAME_RE.fullmatch(n[len("hq/gate/"):])] if m]
    def append(self, rec): self.names.append(f"hq/gate/hwm-{rec['gen']:06d}-{rec['epoch']:012d}-{rec.get('om', 0):09d}-{G._fp_to_name(rec['fp'])}.json")


if __name__ == "__main__":
    unittest.main()
