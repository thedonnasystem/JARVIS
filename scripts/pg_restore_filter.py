"""Which pg_restore stderr lines count as a failed restore (used by scripts/backup_drill.py). Pure function so it can be tested.
Everything starting with 'pg_restore: error' is a failure EXCEPT: 'already exists' / 'errors ignored' (re-creating objects the scratch database already has; unchanged), and exactly one more
case: a pg_restore CLIENT newer than the SERVER sends `SET transaction_timeout = 0;` (a setting added in PostgreSQL 17) and an older server answers
    pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"
    Command was: SET transaction_timeout = 0;
That pair changes no data. Only that exact message is tolerated; any other line that merely mentions the word (a table or column called transaction_timeout_log, a COPY failure) still fails."""
import re

_TOLERATED = re.compile(r'^pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"\s*$')


def restore_errors(stderr: str) -> list:
    out = []
    for line in stderr.splitlines():
        if not line.startswith("pg_restore: error"):
            continue
        if "already exists" in line or "errors ignored" in line:
            continue
        if _TOLERATED.match(line):
            continue
        out.append(line)
    return out
