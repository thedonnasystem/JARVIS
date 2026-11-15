#!/usr/bin/env python3
"""End-to-end proof of the GENERIC https PUT backup path, on local scratch databases and a local fake HTTPS server. No secrets, no external hosts.

  source DB  bk_src          replica schema + synthetic rows (stands in for production)
  target     https://localhost:<port>/store/{name}   a throwaway HTTPS server (self-signed cert generated now, trusted only by this process)
  key/token  generated randomly at start, held in memory/env of this process only, never printed
  restore DB tmpbk_restore   (the restore tool only accepts names starting restore_/drill_/scratch_/tmp)
Runs the real hq_backup.run() and the real ops/restore_backup.py, then failure modes. Usage: python3 scripts/backup_put_e2e.py   (needs local Postgres, password pw)"""
import hashlib, http.server, json, logging, os, secrets, shutil, ssl, subprocess, sys, tempfile, threading, io
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
PG = dict(host=os.environ.get("PGHOST", "localhost"), port=os.environ.get("PGPORT", "5432"))
os.environ["PGPASSWORD"] = os.environ.get("PGPASSWORD", "pw")
SRC = f"postgresql://postgres:pw@{PG['host']}:{PG['port']}/bk_src"
DST = f"postgresql://postgres:pw@{PG['host']}:{PG['port']}/tmpbk_restore"
os.environ.update(REPLICA_URL=SRC, RESTORE_URL=DST)
os.environ["NO_PROXY"] = "localhost,127.0.0.1"; os.environ["no_proxy"] = "localhost,127.0.0.1"
sys.path[:0] = [ROOT, os.path.join(HERE, "replica"), os.path.join(ROOT, "ops"), HERE]
import psycopg2
from cryptography.fernet import Fernet
import backup_drill as D            # seed(), counts()
import hq_backup as B
from pg_adapter import PgAdapter
B._NO_SLEEP = True
results = []


def check(name, ok, detail=""):
    results.append(bool(ok)); print(("PASS  " if ok else "FAIL  ") + name + (f"  [{detail}]" if detail else "")); return ok


class Target:
    """Fake WebDAV-ish PUT target. mode: ok | down(handled by stopping) | 5xx_n (fail n times then ok) | 413 | redirect"""
    def __init__(self, token):
        self.token, self.store, self.log, self.mode, self.fails_left, self.max_bytes = token, {}, [], "ok", 0, None
        outer = self
        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_PUT(self):
                n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
                outer.log.append((self.path, self.headers.get("Authorization") == outer.token, len(body)))
                if self.headers.get("Authorization") != outer.token: return self.send_response(401) or self.end_headers()
                if outer.mode == "redirect": self.send_response(307); self.send_header("Location", "https://example.invalid/x"); return self.end_headers()
                if outer.max_bytes is not None and n > outer.max_bytes: return self.send_response(413) or self.end_headers()
                if outer.fails_left > 0: outer.fails_left -= 1; return self.send_response(503) or self.end_headers()
                outer.store[self.path.rsplit("/", 1)[1]] = body; self.send_response(201); self.end_headers()
        self.H = H
    def start(self, certdir):
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self.H)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(os.path.join(certdir, "c.pem"), os.path.join(certdir, "k.pem"))
        self.srv.socket = ctx.wrap_socket(self.srv.socket, server_side=True); self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
    def stop(self): self.srv.shutdown(); self.srv.server_close()
    @property
    def url(self): return f"https://localhost:{self.port}/store/{{name}}"
    def reset(self): self.store.clear(); self.log.clear(); self.mode = "ok"; self.fails_left = 0; self.max_bytes = None


def psql(db, sql):
    subprocess.run(["psql", "-h", PG["host"], "-p", PG["port"], "-U", "postgres", "-Atqc", sql, db], check=True, capture_output=True)


def main():
    work = tempfile.mkdtemp(prefix="bk_e2e_")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", f"{work}/k.pem", "-out", f"{work}/c.pem", "-days", "1", "-subj", "/CN=localhost",
                    "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"], check=True, capture_output=True)
    os.environ["SSL_CERT_FILE"] = f"{work}/c.pem"     # urllib trusts only this throwaway cert in this process
    for d in ("bk_src", "tmpbk_restore"):
        psql("postgres", f"select pg_terminate_backend(pid) from pg_stat_activity where datname='{d}' and pid<>pg_backend_pid()")
        psql("postgres", f"drop database if exists {d}"); psql("postgres", f"create database {d}")
    subprocess.run(["bash", f"{HERE}/replica/run.sh"], check=True, capture_output=True)
    subprocess.run(["psql", SRC, "-q", "-v", "ON_ERROR_STOP=1", "-f", f"{ROOT}/migrations/20261113_backup_schema_v1.sql"], check=True, capture_output=True)
    c = psycopg2.connect(SRC); D.seed(c); c.close()

    key, token = Fernet.generate_key().decode(), "Bearer " + secrets.token_urlsafe(32)   # random, never printed
    secrets_ = [key, token, token.split(" ", 1)[1]]
    tgt = Target(token); tgt.start(work)
    adapter = PgAdapter(SRC + "?options=-c%20timezone%3DUTC")
    logbuf = io.StringIO(); h = logging.StreamHandler(logbuf); h.setLevel(logging.DEBUG); logging.getLogger().addHandler(h); logging.getLogger().setLevel(logging.DEBUG)
    env = {"BACKUP_KEY": key, "BACKUP_PUT_URL": tgt.url, "BACKUP_AUTH": token}

    def run(extra_env=None, **kw):
        with mock.patch.dict(os.environ, {**env, **(extra_env or {})}), mock.patch("hq._request", side_effect=adapter):
            return B.run(force=True)

    try:
        # 1 happy path
        out = run()
        check("1 run() succeeded over HTTPS PUT with Authorization header", out.get("ok") and out.get("complete"), f'{out.get("rows")} rows')
        names = sorted(tgt.store); enc_name = next(n for n in names if n.endswith(".enc"))
        check("2 target holds exactly the .enc object and its .sha256 sidecar", len(names) == 2 and names[1] == enc_name + ".sha256", ", ".join(names))
        check("3 every PUT carried the correct Authorization header", all(ok for _, ok, _ in tgt.log))
        enc = tgt.store[enc_name]
        pt = [b"Lead 3", b"lead4@example.com", b"example.com", "美味".encode(), b"Reference table", b"capital_mode", b"gzip", b"\x1f\x8b", b"drill_ref"]
        check("4 stored object is ciphertext (no known row values, no gzip magic, starts with Fernet token)", not any(p in enc for p in pt) and enc.startswith(b"gAAAA"))
        check("5 sidecar sha256 matches stored bytes and the audit row", tgt.store[enc_name + ".sha256"].decode().split()[0] == hashlib.sha256(enc).hexdigest() == out["sha256"])
        # 6 restore row-for-row into second scratch DB, using the real restore tool, from the bytes the target received
        fpath = f"{work}/{enc_name}"; open(fpath, "wb").write(enc); open(fpath + ".sha256", "wb").write(tgt.store[enc_name + ".sha256"])
        def restore(keyv, file=fpath, expect=out["sha256"]):
            p = subprocess.run([sys.executable, f"{ROOT}/ops/restore_backup.py", "--file", file, "--wipe", "--expect-sha256", expect, "--report", f"{work}/r.json"],
                               env={**os.environ, "BACKUP_KEY": keyv, "RESTORE_DB_URL": DST}, capture_output=True, text=True, timeout=600)
            try: rep = json.load(open(f"{work}/r.json"))
            except Exception: rep = {}
            os.path.exists(f"{work}/r.json") and os.remove(f"{work}/r.json")
            return p.returncode, rep, p.stdout + p.stderr
        code, rep, _ = restore(key)
        check("6 restore tool: exit 0, PASS, every row + schema identical", code == 0 and rep.get("result") == "PASS" and rep["steps"]["every_row_identical"] == "PASS" and rep["steps"]["schema_identical"] == "PASS", json.dumps(rep.get("steps")))
        tables = list(rep.get("rows") or {})
        a, b = D.counts(SRC, tables), D.counts(DST, tables)
        diff = [t for t in tables if a[t] != b[t]]
        check("7 independent per-table content hash: source DB == restored DB (all tables)", not diff and len(tables) > 40, f"{len(tables)} tables, differing: {diff}")
        # 8 wrong key
        wrong = Fernet.generate_key().decode()
        code, rep, txt = restore(wrong)
        check("8 wrong BACKUP_KEY at restore: refused with a clear message, nonzero exit", code != 0 and "wrong BACKUP_KEY" in txt and wrong not in txt, f"exit {code}")
        # 9 bad auth
        tgt.reset(); n_before = len(tgt.store)
        o = run({"BACKUP_AUTH": "Bearer " + secrets.token_urlsafe(32)})
        check("9 bad auth: run fails clearly (HTTP 401, 'check BACKUP_AUTH'), nothing stored", not o["ok"] and "401" in o["reason"] and "BACKUP_AUTH" in o["reason"] and len(tgt.store) == n_before == 0, o["reason"])
        # 10 invalid key at backup time
        o = run({"BACKUP_KEY": "not-a-key"}); tgt_n = len(tgt.store)
        check("10 invalid BACKUP_KEY: clear failure, nothing uploaded", not o["ok"] and "BACKUP_KEY" in o["reason"] and tgt_n == 0, o["reason"])
        # 11 oversized
        tgt.reset(); tgt.max_bytes = 1000
        o = run()
        check("11 oversized (target answers 413): clear failure, no stored object", not o["ok"] and "413" in o["reason"] and not tgt.store, o["reason"])
        # 12 transient 503 then ok -> retry succeeds
        tgt.reset(); tgt.fails_left = 2
        o = run()
        check("12 two transient 503s then OK: retried within the run, backup succeeds", o["ok"] and len(tgt.store) == 2, f"{len(tgt.log)} PUT attempts")
        # 13 persistent 503
        tgt.reset(); tgt.fails_left = 99
        o = run()
        check("13 persistent 503: fails after bounded retries, nothing stored", not o["ok"] and "503" in o["reason"] and not tgt.store and len(tgt.log) == B.PUT_ATTEMPTS, f'{len(tgt.log)} attempts: {o["reason"]}')
        # 14 redirect not followed (auth never leaves the host)
        tgt.reset(); tgt.mode = "redirect"
        o = run()
        check("14 redirect to another host is not followed: clear failure", not o["ok"] and "307" in o["reason"], o["reason"])
        # 15 target down
        tgt.reset(); tgt.stop()
        o = run()
        check("15 target down: bounded retries then clear 'unreachable' failure", not o["ok"] and "unreachable" in o["reason"], o["reason"])
        # 16 failure alerting + backoff gate: failure audit row + one owner message; secrets absent everywhere
        fails = adapter("GET", "/rest/v1/audit_log?action=eq.backup_failed&select=detail,at")
        msgs = adapter("GET", "/rest/v1/owner_messages?select=body,kind&body=ilike.*Backup*")
        check("16 failures were audited (backup_failed rows) and the owner was alerted ONCE per day", len(fails) >= 5 and len([m for m in msgs if "Backup failed" in m["body"]]) == 1, f"{len(fails)} failed rows, {len(msgs)} owner messages")
        blob = json.dumps(fails, default=str) + json.dumps(msgs, default=str) + json.dumps(adapter("GET", "/rest/v1/audit_log?select=*"), default=str)
        leaked = [i for i, sct in enumerate(secrets_) if sct in blob or sct in logbuf.getvalue()]
        check("17 secrets (BACKUP_KEY, auth token) appear in no audit row, owner message or log record", not leaked, f"leaks: {leaked}")
        # 18 real due() gate: after 3 failures within the night the next call is refused
        with mock.patch("hq._request", side_effect=adapter):
            from datetime import datetime, timezone
            d = B.due(datetime.now(timezone.utc).replace(hour=8, minute=0))   # 03-04 Toronto window
        check("18 due() gate stops retries after the daily failure cap / retry gap", d is False, "")
    finally:
        try: tgt.stop()
        except Exception: pass
        sys.stdout.flush()
        for d in ("bk_src", "tmpbk_restore"):
            psql("postgres", f"select pg_terminate_backend(pid) from pg_stat_activity where datname='{d}' and pid<>pg_backend_pid()")
            psql("postgres", f"drop database if exists {d}")
        shutil.rmtree(work, ignore_errors=True)
    print(f"\n{sum(results)}/{len(results)} checks passed"); sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
