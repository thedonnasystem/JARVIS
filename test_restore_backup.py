import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "ops"))
import restore_backup as R


class Guard(unittest.TestCase):
    def refused(self, dsn, text=""):
        with self.assertRaises(R.Fail) as c:
            R.assert_scratch(dsn)
        self.assertIn(text, str(c.exception))

    def test_accepts_explicit_local_scratch(self):
        self.assertEqual(R.assert_scratch("postgresql://u:p@127.0.0.1:5433/restore_x")["database"], "restore_x")
        self.assertEqual(R.assert_scratch("dbname=drill_a host=localhost user=postgres")["host"], "localhost")
        self.assertEqual(R.assert_scratch("dbname=tmp_a host=/var/run/postgresql")["host"], "unix-socket")

    def test_refuses_redirects_and_non_local(self):
        self.refused("dbname=restore_x host=localhost hostaddr=10.1.2.3", "hostaddr")
        self.refused("dbname=restore_x host=localhost service=prod", "service")
        self.refused("dbname=restore_x user=postgres", "explicit local host")
        self.refused("postgresql://u:p@db.example.com/restore_x", "not local")
        self.refused("postgresql://u:p@localhost,db.example.com/restore_x", "")
        self.refused("postgresql://u:p@localhost/postgres", "must start with")
        self.refused("postgresql://u:p@localhost/restore_x?options=-c%20x", "options")
        self.refused("postgresql://u:p@db.ihxzvpwbqydqtblvazbq.supabase.co/restore_x", "")

    def test_refuses_unparseable(self):
        self.refused("%%%not a dsn%%%", "")


class Acl(unittest.TestCase):
    def test_grants_parse(self):
        got = R._acl_grants(["pg_database_owner=UC/pg_database_owner", "=U/pg_database_owner", "anon=U/postgres", '"odd role"=UC/postgres'])
        self.assertEqual(sorted(got), sorted(["PUBLIC:USAGE", "anon:USAGE", "odd role:USAGE", "odd role:CREATE"]))

    def test_empty(self):
        self.assertEqual(R._acl_grants(None), [])


if __name__ == "__main__":
    unittest.main()


class SuppressionPayload(unittest.TestCase):
    """The restore tool's own, independent re-check of the keyed-hash list, and the gate it sets on a restored database."""
    @staticmethod
    def payload(macs=(("email", "a" * 64), ("phone", "b" * 64))):
        import hashlib
        lines = sorted(f"{k}:{m}" for k, m in macs)
        return {"version": 1, "included": True, "key_check": "e" * 64, "count": len(lines), "email_count": sum(1 for k, _ in macs if k == "email"),
                "phone_count": sum(1 for k, _ in macs if k == "phone"), "hash": hashlib.sha256("\n".join(lines).encode()).hexdigest(), "macs": [list(m) for m in macs]}

    def test_good_and_bad(self):
        self.assertEqual(R.check_suppression_payload(self.payload()), [])
        self.assertEqual(R.check_suppression_payload(self.payload(())), [])
        p = self.payload(); p["macs"].pop()
        self.assertTrue(R.check_suppression_payload(p))
        p = self.payload(); p["macs"][0][1] = "0" * 64
        self.assertTrue(R.check_suppression_payload(p))
        p = self.payload(); p["macs"].append(p["macs"][0])
        self.assertTrue(R.check_suppression_payload(p))
        for bad in (None, {}, {"version": 2}, {**self.payload(), "macs": [["x", "a" * 64]]}, {**self.payload(), "macs": [["email", "alice@example.com"]]}, {**self.payload(), "key_check": "x"}):
            self.assertTrue(R.check_suppression_payload(bad))

    def test_agrees_with_the_bot_side_validator(self):
        import hq_consent as C
        for macs in ([], [("email", "a" * 64)], [("email", "a" * 64), ("phone", "b" * 64), ("phone", "c" * 64)]):
            p = self.payload(macs)
            self.assertEqual(R.check_suppression_payload(p) == [], C.validate_suppression_export(p) == [])
            self.assertEqual(p["hash"], C.suppression_digest(macs)["hash"])

    class Cur:
        def __init__(self, tables=True, opened=False):
            self.sql, self.params, self.tables, self.opened, self.last = [], [], tables, opened, None
        def execute(self, q, p=None):
            self.sql.append(" ".join(q.split())); self.params.append(p); self.last = " ".join(q.split())
        def executemany(self, q, rows):
            self.sql.append(" ".join(q.split())); self.params.append(list(rows))
        def fetchone(self):
            q = self.last
            if "to_regclass" in q: return (self.tables,)
            if "ffm_outreach_gate_open" in q: return (self.opened,)
            if "select state from" in q: return ("unverified",)
            return (0,)

    def test_gate_is_closed_and_checkpoint_staged(self):
        rep, cur = {}, self.Cur()
        self.assertTrue(R.apply_gate(cur, rep, self.payload()))
        g = rep["outreach_gate"]
        self.assertEqual((g["state"], g["open"], g["checkpoint_staged"], g["checkpoint"]["count"]), ("unverified", False, True, 2))
        self.assertTrue(any("insert into public.ffm_suppression_expected" in q for q in cur.sql))
        self.assertGreaterEqual(len(rep["next_steps"]), 4)
        self.assertFalse(any("'verified'" in q and "set state = 'verified'" in q for q in cur.sql))      # the tool only ever closes the gate

    def test_without_checkpoint_and_with_open_gate(self):
        rep = {}
        self.assertTrue(R.apply_gate(self.Cur(), rep, None))
        self.assertFalse(rep["outreach_gate"]["checkpoint_staged"]); self.assertIn("no checkpoint", rep["outreach_gate"]["note"])
        rep = {}
        self.assertFalse(R.apply_gate(self.Cur(opened=True), rep, None))        # would allow outreach: the restore must FAIL

    def test_old_schema_without_a_gate_is_loud(self):
        rep = {}
        self.assertTrue(R.apply_gate(self.Cur(tables=False), rep, self.payload()))
        self.assertEqual(rep["outreach_gate"]["state"], "NOT PRESENT"); self.assertIn("APPLY", rep["next_steps"][0])
