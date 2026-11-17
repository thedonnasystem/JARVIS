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

    def test_restore_marker_and_epoch_are_written_by_the_tool_and_the_gate_only_closes(self):
        """v3: the restore writes a restore MARKER and recreates the epoch row (lower than the sender's outside mark), before it touches the gate row."""
        for sup in (self.payload(), None):
            rep, cur = {}, self.Cur()
            self.assertTrue(R.apply_gate(cur, rep, sup, file_sha="ab" * 32))
            m = [i for i, q in enumerate(cur.sql) if "insert into public.ffm_restore_markers" in q]
            e = [i for i, q in enumerate(cur.sql) if "insert into public.ffm_epoch" in q]
            g = [i for i, q in enumerate(cur.sql) if "insert into public.ffm_outreach_gate" in q]
            self.assertEqual((len(m), len(e), len(g)), (1, 1, 1)); self.assertLess(m[0], g[0]); self.assertLess(e[0], g[0])
            self.assertIn("sha256 " + "ab" * 8, cur.params[m[0]][0]); self.assertTrue(rep["outreach_gate"]["restore_marker_recorded"])
            self.assertTrue(any("verified_epoch = null" in q and "attested_at = null" in q and "instance_fp = null" in q for q in cur.sql))     # every v3 verification column is cleared
            self.assertFalse(any("delete from public.ffm_restore_markers" in q or "update public.ffm_restore_markers" in q for q in cur.sql))
        rep = {}
        class NoMarkers(self.Cur):
            def fetchone(s):
                if s.last and "ffm_restore_markers') is not null" in s.last: return (False,)
                return super().fetchone()
        self.assertFalse(R.apply_gate(NoMarkers(), rep, self.payload()))      # a schema without the marker table cannot be made safe: FAIL
        self.assertIn("APPLY", rep["next_steps"][0])

    def test_marker_gate_and_data_commit_together(self):
        """The restore must not COMMIT between loading the data and writing the marker / closed gate (one transaction, one commit)."""
        import os, re
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ops", "restore_backup.py")) as fh: src = fh.read()
        body = src[src.index("replay_schema_acl_and_comments(cur, schema, rep)\n"):src.index("apply_gate(cur, rep, sup")]
        self.assertNotIn("conn.commit()", body)

    def test_without_checkpoint_and_with_open_gate(self):
        rep = {}
        self.assertTrue(R.apply_gate(self.Cur(), rep, None))
        self.assertFalse(rep["outreach_gate"]["checkpoint_staged"]); self.assertIn("no checkpoint", rep["outreach_gate"]["note"])
        rep = {}
        self.assertFalse(R.apply_gate(self.Cur(opened=True), rep, None))        # would allow outreach: the restore must FAIL

    def test_old_schema_without_a_gate_FAILS_the_restore(self):
        """PR #15 review finding 5: a restored schema with no outreach gate left outreach ungated yet reported PASS. It must FAIL."""
        rep = {}
        self.assertFalse(R.apply_gate(self.Cur(tables=False), rep, self.payload()))
        self.assertEqual(rep["outreach_gate"]["state"], "NOT PRESENT"); self.assertIn("APPLY", rep["next_steps"][0]); self.assertIn("FAILS", rep["outreach_gate"]["note"])
        rep = {}
        self.assertFalse(R.apply_gate(self.Cur(tables=False), rep, None))

    def test_untrusted_checkpoint_is_not_staged(self):
        """Finding 6: without an independently recorded file hash the checkpoint in the file is ignored (verifying against it would be a tautology); the gate stays closed."""
        rep, cur = {}, self.Cur()
        self.assertTrue(R.apply_gate(cur, rep, self.payload(), checkpoint_trusted=False))
        g = rep["outreach_gate"]
        self.assertFalse(g["checkpoint_staged"]); self.assertIn("NOT staged", g["checkpoint_ignored"]); self.assertEqual((g["state"], g["open"]), ("unverified", False))
        self.assertFalse(any("insert into public.ffm_suppression_expected" in q for q in cur.sql))

    def test_a_restore_requires_expect_sha256_or_the_explicit_flag(self):
        import subprocess, sys, os
        here = os.path.dirname(os.path.abspath(__file__))
        for args in (["--file", "x.enc", "--wipe"], ["--b2-latest"]):
            r = subprocess.run([sys.executable, "-I", os.path.join(here, "ops", "restore_backup.py")] + args, capture_output=True, text=True)
            self.assertEqual(r.returncode, 2); self.assertIn("--expect-sha256", r.stderr); self.assertIn("--i-accept-unverified-suppression", r.stderr)
        r = subprocess.run([sys.executable, "-I", os.path.join(here, "ops", "restore_backup.py"), "--file", "x.enc", "--i-accept-unverified-suppression"], capture_output=True, text=True, env={**os.environ, "BACKUP_KEY": ""})
        self.assertNotIn("a restore needs --expect-sha256", r.stderr)      # the flag is accepted (it then fails later for its own reasons: no such file / no key)
