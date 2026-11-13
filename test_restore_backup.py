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
