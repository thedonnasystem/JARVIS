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


class UniqueBlanks(unittest.TestCase):
    """E2a: a blanked column inside a UNIQUE index must not collapse rows onto one value."""
    SCHEMA = {"tables": [{"name": "evidence_sources", "columns": [{"name": "task_id", "type": "uuid", "notnull": True}, {"name": "content_sha256", "type": "text", "notnull": True},
                                                                    {"name": "url", "type": "text", "notnull": True}, {"name": "final_url", "type": "text", "notnull": True}]}],
              "indexes": [{"table": "evidence_sources", "name": "evidence_sources_dedupe_idx",
                           "def": "CREATE UNIQUE INDEX evidence_sources_dedupe_idx ON public.evidence_sources USING btree (task_id, content_sha256, final_url)"}], "constraints": []}
    MAN = {"redaction": {"blanked_columns": ["evidence_sources.url", "evidence_sources.final_url"]}}

    def rows(self):
        return {"evidence_sources": [{"task_id": "t1", "content_sha256": "h", "url": "https://a.example/x", "final_url": "https://a.example/x"},
                                      {"task_id": "t1", "content_sha256": "h", "url": "https://b.example/y", "final_url": "https://b.example/y"}]}

    def test_blanked_unique_column_gets_a_distinct_value_per_row(self):
        data = self.rows()
        R.apply_blanks(self.SCHEMA, data, self.MAN, {})
        vals = [r["final_url"] for r in data["evidence_sources"]]
        self.assertEqual(len(set(vals)), 2); self.assertTrue(all(len(v) >= 30 and v.startswith(R.BLANK_MARKER) for v in vals))
        R.assert_unique_feasible(self.SCHEMA, data)                      # no exception: the index can be built

    def test_the_old_collapse_is_caught_before_anything_is_loaded(self):
        data = self.rows()
        for r in data["evidence_sources"]:
            r["final_url"] = ""                                          # what the old restore produced
        with self.assertRaises(R.Fail) as cm:
            R.assert_unique_feasible(self.SCHEMA, data)
        self.assertIn("evidence_sources_dedupe_idx", str(cm.exception)); self.assertIn("nothing was loaded", str(cm.exception))

    def test_nulls_are_distinct_and_partial_or_expression_indexes_are_skipped(self):
        sch = {"tables": [], "constraints": [{"table": "t", "type": "u", "name": "u1", "def": "UNIQUE (a, b)"}],
               "indexes": [{"table": "t", "name": "p", "def": "CREATE UNIQUE INDEX p ON public.t USING btree (a) WHERE (b IS NULL)"}, {"table": "t", "name": "e", "def": "CREATE UNIQUE INDEX e ON public.t USING btree (lower(a))"}]}
        R.assert_unique_feasible(sch, {"t": [{"a": "x", "b": None}, {"a": "x", "b": None}]})      # NULL in b: distinct
        with self.assertRaises(R.Fail):
            R.assert_unique_feasible(sch, {"t": [{"a": "x", "b": 1}, {"a": "x", "b": 1}]})


if __name__ == "__main__":
    unittest.main()
