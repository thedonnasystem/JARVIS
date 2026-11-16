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


class Blanks(unittest.TestCase):
    SCHEMA = {"tables": [{"name": "tasks", "columns": [{"name": "result", "type": "text", "notnull": False}, {"name": "title", "type": "text", "notnull": True}, {"name": "tags", "type": "text[]", "notnull": True}, {"name": "meta", "type": "jsonb", "notnull": True}, {"name": "kind", "type": "text", "notnull": True}]}]}

    def test_blank_columns_restore_empty_and_keep_not_null(self):
        data = {"tasks": [{"id": 1, "result": "", "title": "", "tags": None, "meta": None, "kind": "x"}]}
        rep = {}
        R.apply_blanks(self.SCHEMA, data, {"redaction": {"blanked_columns": ["tasks.result", "tasks.title", "tasks.tags", "tasks.meta"]}}, rep)
        r = data["tasks"][0]
        self.assertIsNone(r["result"])                                  # nullable -> NULL
        self.assertEqual((r["title"], r["tags"], r["meta"]), ("", [], {}))   # NOT NULL -> empty value of the right type
        self.assertEqual(r["kind"], "x")                                 # not blanked: untouched
        self.assertEqual(rep["blanked_fields_restored_empty"], 4)

    def test_check_constraint_columns_get_a_marker_that_satisfies_them(self):
        schema = {"tables": [{"name": "memory", "columns": [{"name": "source", "type": "text", "notnull": False}]}, {"name": "payment_instructions", "columns": [{"name": "payee", "type": "text", "notnull": True}]}],
                  "constraints": [{"table": "memory", "type": "c", "name": "memory_fact_needs_source", "def": "CHECK (((kind <> 'fact'::text) OR (source IS NOT NULL)))"},
                                  {"table": "payment_instructions", "type": "c", "name": "p", "def": "CHECK ((length(payee) >= 2))"}]}
        data = {"memory": [{"source": ""}], "payment_instructions": [{"payee": ""}]}
        R.apply_blanks(schema, data, {"redaction": {"blanked_columns": ["memory.source", "payment_instructions.payee"]}}, {})
        self.assertEqual(data["memory"][0]["source"], R.BLANK_MARKER)       # not NULL, not ''
        self.assertGreaterEqual(len(data["payment_instructions"][0]["payee"]), 20)      # the longest minimum-length CHECK on a blanked column is >= 20

    def test_not_null_json_column_with_an_array_default_restores_as_an_array(self):
        schema = {"tables": [{"name": "missions", "columns": [{"name": "plan", "type": "jsonb", "notnull": True, "default": "'[]'::jsonb"}, {"name": "meta", "type": "jsonb", "notnull": True, "default": "'{}'::jsonb"}]}]}
        data = {"missions": [{"plan": None, "meta": None}]}
        R.apply_blanks(schema, data, {"redaction": {"blanked_columns": ["missions.plan", "missions.meta"]}}, {})
        self.assertEqual((data["missions"][0]["plan"], data["missions"][0]["meta"]), ([], {}))

    def test_unlisted_column_is_never_touched(self):
        data = {"tasks": [{"id": 1, "result": "keep me", "title": "t", "tags": ["a"], "meta": {"a": 1}, "kind": "x"}]}
        R.apply_blanks(self.SCHEMA, data, {"redaction": {"blanked_columns": []}}, {})
        self.assertEqual(data["tasks"][0]["result"], "keep me")

    def test_missing_table_or_column_is_ignored(self):
        data = {"tasks": [{"id": 1}]}
        R.apply_blanks(self.SCHEMA, data, {"redaction": {"blanked_columns": ["nope.x", "tasks.nope"]}}, {})
        self.assertEqual(data["tasks"][0], {"id": 1})


if __name__ == "__main__":
    unittest.main()
