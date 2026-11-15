import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pg_restore_filter import restore_errors as R


class T(unittest.TestCase):
    def test_the_exact_newer_client_message_is_tolerated(self):
        e = 'pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"\nCommand was: SET transaction_timeout = 0;\n'
        self.assertEqual(R(e), [])

    def test_anything_else_mentioning_the_word_still_fails(self):
        for e in ('pg_restore: error: COPY failed for table "transaction_timeout_log": ERROR:  invalid input\n',
                  'pg_restore: error: could not execute query: ERROR:  relation "transaction_timeout" does not exist\n',
                  'pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout_x"\n',
                  'pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout" extra\n',
                  'pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "lock_timeout"\n',
                  'pg_restore: error: could not execute query: ERROR:  syntax error\nCommand was: SET transaction_timeout = 0;\n'):
            self.assertEqual(len(R(e)), 1, e)

    def test_existing_tolerances_and_noise(self):
        self.assertEqual(R('pg_restore: error: could not execute query: ERROR:  schema "public" already exists\npg_restore: warning: errors ignored on restore: 1\n'), [])
        self.assertEqual(R("some other line\nWARNING: x\n"), [])


if __name__ == "__main__":
    unittest.main()
