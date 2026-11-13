#!/usr/bin/env python3
"""Restore an HQ backup into a SCRATCH Postgres and prove the result. Never touches production.

Needs: python3, `pip install cryptography psycopg2-binary`, and a scratch Postgres you can wipe (any local Postgres 15+; a superuser is needed
because triggers are switched off while rows are loaded).

  export BACKUP_KEY=...                       # the Fernet key (never pass it on the command line)
  export RESTORE_DB_URL=postgresql://postgres:pw@localhost:5432/restore_drill    # database name MUST start with restore_/drill_/scratch_/tmp
  python3 ops/restore_backup.py --file hq-20261113T070000Z.tar.gz.enc --wipe --report report.json
  # or straight from Backblaze B2 with a READ key (listFiles + readFiles on the bucket):
  export RESTORE_B2_AUTH=keyId:applicationKey RESTORE_B2_BUCKET_ID=<bucketId> [RESTORE_B2_PREFIX=hq/]
  python3 ops/restore_backup.py --b2-latest --wipe --report report.json

What it checks, in order (any failure => non-zero exit, and the report says which):
  1 the encrypted file's sha256 equals its .sha256 sidecar (and --expect-sha256 if given, e.g. the value in audit_log)
  2 it decrypts with BACKUP_KEY; manifest, schema.json and every table file match the manifest's sha256 and row counts
  3 the schema (extensions, sequences, tables, functions, constraints, indexes, triggers, views, RLS, policies, grants) is rebuilt from schema.json
  4 every row is loaded; foreign keys are validated; sequences are advanced
  5 every restored row equals the backed-up row (multiset comparison of canonical JSON), table by table
  6 the restored database describes itself (public.backup_schema()) exactly as the backup said: functions (body hash + who may run them), triggers,
    indexes, constraints, views, policies, grants
  7 smoke tests that exercise restored functions (spend gateway refuses when the kill switch is on; capital_mode() runs)
Limits are printed in the report ("not_restored"): cron jobs, default privileges for FUTURE objects, extensions the scratch server lacks, anything outside public."""
import argparse, base64, collections, datetime as dt, hashlib, io, json, os, re, sys, tarfile, urllib.error, urllib.parse, urllib.request
from decimal import Decimal

SAFE_DB = re.compile(r"^(restore|drill|scratch|tmp)[a-z0-9_]*$")
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", ""}
B2_AUTH_URL = os.environ.get("RESTORE_B2_AUTH_URL", "https://api.backblazeb2.com/b2api/v4/b2_authorize_account")
FK_LAST = ("p", "u", "x", "c", "f")


class Fail(Exception):
    pass


def qi(x: str) -> str:
    return '"' + str(x).replace('"', '""') + '"'


# ------------------------------------------------------------------ safety

FORBIDDEN_DSN_KEYS = ("hostaddr", "service", "servicefile", "passfile", "options", "target_session_attrs")
SUPABASE_SCHEMAS = ("auth", "storage", "realtime", "vault", "supabase_functions", "pgbouncer", "graphql", "graphql_public", "_realtime", "pgsodium")
SUPABASE_ROLES = ("supabase_admin", "supabase_auth_admin", "supabase_storage_admin", "supabase_read_only_user", "authenticator", "pgbouncer")
MAX_ENC_BYTES = 512 * 1024 * 1024         # a real backup is under 1 MB; refuse absurd inputs (memory bombs)
MAX_UNPACKED_BYTES = 1024 * 1024 * 1024


def scrub_environment() -> None:
    """libpq reads host/service defaults from the environment; a stray PGHOST must never redirect a 'local' restore."""
    for k in ("PGHOST", "PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE", "PGOPTIONS", "PGTARGETSESSIONATTRS"):
        os.environ.pop(k, None)


def assert_scratch(dsn: str) -> dict:
    """Refuse anything that is not an explicitly local database whose name says it is disposable. (Name + host checks here; the connected
    server is checked again by assert_not_supabase() before anything is dropped.)"""
    import psycopg2.extensions as ext
    try:
        p = ext.parse_dsn(dsn)
    except Exception:
        raise Fail("refusing: connection string could not be parsed")
    bad = [k for k in FORBIDDEN_DSN_KEYS if k in p]
    if bad:
        raise Fail(f"refusing: connection string uses {', '.join(bad)}, which can redirect the connection away from the host that was checked.")
    host, db = (p.get("host") or ""), (p.get("dbname") or "")
    if not host:
        raise Fail("refusing: give an explicit local host (localhost, 127.0.0.1, ::1 or a unix socket directory); an empty host falls back to environment defaults.")
    if "," in host:
        raise Fail("refusing: multiple hosts are not allowed.")
    if not (host.startswith("/") or host in LOCAL_HOSTS):
        raise Fail(f"refusing: host '{host}' is not local. This tool only restores into a scratch database on this machine.")
    if not SAFE_DB.match(db):
        raise Fail(f"refusing: database name '{db}' must start with restore_, drill_, scratch_ or tmp (so it cannot be a real database).")
    if "supabase" in dsn.lower():
        raise Fail("refusing: connection string mentions supabase.")
    prod = urllib.parse.urlparse(os.environ.get("HQ_SUPABASE_URL", "")).hostname
    if prod and prod in dsn:
        raise Fail("refusing: connection string mentions the production host.")
    return {"host": "unix-socket" if host.startswith("/") else host, "database": db}


def assert_not_supabase(cur) -> None:
    """After connecting (and before dropping anything): the server must not look like a Supabase project, e.g. one reached through a tunnel."""
    cur.execute("select current_database()")
    db = cur.fetchone()[0]
    if not SAFE_DB.match(db):
        raise Fail(f"refusing: connected database is '{db}', not a scratch name.")
    cur.execute("select nspname from pg_namespace where nspname = any(%s)", (list(SUPABASE_SCHEMAS),))
    found = [r[0] for r in cur.fetchall()]
    cur.execute("select rolname from pg_roles where rolname = any(%s)", (list(SUPABASE_ROLES),))
    found += [r[0] for r in cur.fetchall()]
    if found:
        raise Fail("refusing: the connected server looks like a Supabase project (" + ", ".join(sorted(set(found))[:4]) + "). Nothing was changed.")


# ------------------------------------------------------------------ fetch

def _http(method, url, headers=None, body=None, timeout=120):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers or {})


def b2_session():
    auth, bucket = os.environ.get("RESTORE_B2_AUTH", ""), os.environ.get("RESTORE_B2_BUCKET_ID", "")
    if ":" not in auth or not bucket:
        raise Fail("set RESTORE_B2_AUTH=keyId:applicationKey and RESTORE_B2_BUCKET_ID")
    st, body, _ = _http("GET", B2_AUTH_URL, {"Authorization": "Basic " + base64.b64encode(auth.encode()).decode()}, timeout=30)
    if st != 200:
        raise Fail(f"B2 authorize failed (HTTP {st})")
    j = json.loads(body)
    s = (j.get("apiInfo") or {}).get("storageApi") or j
    return {"token": j["authorizationToken"], "api": s["apiUrl"], "bucket": bucket, "prefix": os.environ.get("RESTORE_B2_PREFIX", "")}


def b2_list(s) -> list:
    st, body, _ = _http("POST", f"{s['api']}/b2api/v4/b2_list_file_names", {"Authorization": s["token"], "Content-Type": "application/json"},
                        json.dumps({"bucketId": s["bucket"], "prefix": s["prefix"], "maxFileCount": 10000}).encode(), 60)
    if st != 200:
        raise Fail(f"B2 list failed (HTTP {st}); the key needs listFiles")
    return [f for f in json.loads(body)["files"] if f.get("action", "upload") == "upload"]


def b2_get(s, f) -> bytes:
    st, body, hdr = _http("GET", f"{s['api']}/b2api/v4/b2_download_file_by_id?fileId={urllib.parse.quote(f['fileId'])}", {"Authorization": s["token"]})
    if st != 200:
        raise Fail(f"B2 download failed (HTTP {st}); the key needs readFiles")
    if len(body) > MAX_ENC_BYTES:
        raise Fail("download refused: implausibly large for a backup")
    sha1 = {k.lower(): v for k, v in hdr.items()}.get("x-bz-content-sha1", "")
    if sha1 and not sha1.startswith("unverified") and sha1 != hashlib.sha1(body).hexdigest():
        raise Fail("downloaded bytes do not match B2's SHA-1")
    return body


def fetch(args) -> tuple[bytes, str | None, str]:
    """Returns (encrypted bytes, sidecar text or None, name)."""
    if args.file:
        if os.path.getsize(args.file) > MAX_ENC_BYTES:
            raise Fail("file refused: implausibly large for a backup")
        enc = open(args.file, "rb").read()
        side = args.sidecar or args.file + ".sha256"
        return enc, (open(side).read() if os.path.exists(side) else None), os.path.basename(args.file)
    s = b2_session()
    files = b2_list(s)
    encs = sorted((f for f in files if f["fileName"].endswith(".tar.gz.enc")), key=lambda f: f["fileName"])
    if args.list:
        for f in encs:
            print(f["fileName"], f.get("contentLength"))
        sys.exit(0)
    if not encs:
        raise Fail("no backups found in that bucket/prefix")
    pick = next((f for f in encs if f["fileName"].endswith(args.b2_name)), None) if args.b2_name else encs[-1]
    if not pick:
        raise Fail(f"no backup named {args.b2_name}")
    side = next((f for f in files if f["fileName"] == pick["fileName"] + ".sha256"), None)
    return b2_get(s, pick), (b2_get(s, side).decode() if side else None), pick["fileName"]


# ------------------------------------------------------------------ verify the file

def open_archive(enc: bytes, sidecar: str | None, name: str, expect: str | None, rep: dict) -> tuple[dict, dict, dict]:
    from cryptography.fernet import Fernet, InvalidToken
    sha = hashlib.sha256(enc).hexdigest()
    rep["file"] = {"name": name, "bytes": len(enc), "sha256": sha}
    if sidecar:
        want = sidecar.split()[0].strip().lower()
        rep["file"]["sidecar_sha256_ok"] = (want == sha)
        if want != sha:
            raise Fail(f"checksum mismatch: file {sha} vs sidecar {want}")
    else:
        rep["file"]["sidecar_sha256_ok"] = None
    if expect:
        rep["file"]["expected_sha256_ok"] = (expect.lower() == sha)
        if expect.lower() != sha:
            raise Fail(f"checksum mismatch: file {sha} vs --expect-sha256 {expect}")
    try:
        plain = Fernet(os.environ["BACKUP_KEY"].encode()).decrypt(enc)
    except KeyError:
        raise Fail("BACKUP_KEY is not set")
    except InvalidToken:
        raise Fail("cannot decrypt: wrong BACKUP_KEY or the file is damaged")
    rep["file"]["decrypts"] = True
    tar = tarfile.open(fileobj=io.BytesIO(plain), mode="r:gz")
    if sum(m.size for m in tar.getmembers() if m.isfile()) > MAX_UNPACKED_BYTES:
        raise Fail("archive refused: unpacked size is implausibly large")
    members = {m.name: tar.extractfile(m).read() for m in tar.getmembers() if m.isfile()}
    manifest = json.loads(members["manifest.json"])
    if manifest.get("format") != 2:
        raise Fail(f"unsupported backup format {manifest.get('format')}")
    bad = []
    for t, meta in manifest["tables"].items():
        raw = members.get(f"data/{t}.jsonl")
        if raw is None:
            bad.append(f"{t}: missing"); continue
        n = len([ln for ln in raw.decode().split("\n") if ln.strip()])
        if hashlib.sha256(raw).hexdigest() != meta["sha256"] or n != meta["rows"]:
            bad.append(f"{t}: content differs from manifest")
    schema = {}
    if manifest.get("schema"):
        raw = members.get("schema.json", b"")
        if hashlib.sha256(raw).hexdigest() != manifest["schema"]["sha256"]:
            bad.append("schema.json: content differs from manifest")
        else:
            schema = json.loads(raw)
    extra = sorted(n for n in members if n.startswith("data/") and n[5:-6] not in manifest["tables"])
    rep["archive"] = {"format": 2, "created_utc": manifest["created_utc"], "engine_build": manifest.get("engine_build"), "complete": manifest["complete"],
                      "tables": len(manifest["tables"]), "total_rows": manifest["total_rows"], "problems": bad, "unlisted_data_files": extra,
                      "table_list_source": manifest.get("table_list_source"),
                      "consistency": manifest.get("consistency")}
    if bad:
        raise Fail("archive integrity: " + "; ".join(bad[:5]))
    data = {t: [json.loads(ln) for ln in members[f"data/{t}.jsonl"].decode().split("\n") if ln.strip()] for t in manifest["tables"]}
    return manifest, schema, data


# ------------------------------------------------------------------ rebuild

def _try(cur, sql, params=None):
    cur.execute("savepoint s")
    try:
        cur.execute(sql, params)
        cur.execute("release savepoint s")
        return None
    except Exception as e:
        cur.execute("rollback to savepoint s")
        return str(e).strip().split("\n")[0]


def table_sql(t: dict) -> str:
    cols = []
    for c in t["columns"]:
        s = f'{qi(c["name"])} {c["type"]}'
        if c.get("generated") == "s":
            s += f' GENERATED ALWAYS AS ({c["default"]}) STORED'
        elif c.get("identity") == "a":
            s += " GENERATED ALWAYS AS IDENTITY"
        elif c.get("identity") == "d":
            s += " GENERATED BY DEFAULT AS IDENTITY"
        elif c.get("default") is not None:
            s += f' DEFAULT {c["default"]}'
        if c.get("notnull"):
            s += " NOT NULL"
        cols.append(s)
    return f'CREATE TABLE public.{qi(t["name"])} ({", ".join(cols)})'


def rebuild_schema(cur, schema: dict, rep: dict):
    skipped = collections.defaultdict(list)
    cur.execute("set check_function_bodies = off")
    cur.execute("create schema if not exists public")
    roles = {"anon", "authenticated", "service_role"}
    for g in schema.get("table_grants", []):
        roles.add(g["grantee"])
    for f in schema.get("functions", []):
        roles.update(f.get("acl", []))
    for d in schema.get("default_privileges", []):
        roles.add(d["role"])
    for p in schema.get("policies", []):
        roles.update(r for r in (p.get("roles") or []) if r)
    roles.update(g.split(":")[0] for g in _acl_grants(schema.get("schema_acl")))
    cur.execute("select current_user")
    me = cur.fetchone()[0]
    for r in sorted(roles - {"PUBLIC", "public", "postgres", me}):
        cur.execute("select 1 from pg_roles where rolname=%s", (r,))
        if not cur.fetchone():
            cur.execute(f"create role {qi(r)} nologin")
    for e in schema.get("extensions", []):
        if e["name"] == "plpgsql":
            continue
        cur.execute(f'create schema if not exists {qi(e["schema"])}')
        err = _try(cur, f'create extension if not exists {qi(e["name"])} schema {qi(e["schema"])}')
        if err:
            skipped["extensions_unavailable"].append(f'{e["name"]}: {err[:80]}')
    for e in schema.get("enums", []):
        labels = ", ".join("'" + x.replace("'", "''") + "'" for x in e["labels"])
        cur.execute(f'create type public.{qi(e["name"])} as enum ({labels})')
    for d in schema.get("domains", []):
        cur.execute(f'create domain public.{qi(d["name"])} as {d["base"]}' + (f' default {d["default"]}' if d.get("default") else "") + (" not null" if d["notnull"] else "")
                    + "".join(f" {c}" for c in d.get("checks", [])))
    used = " ".join((c.get("default") or "") for t in schema["tables"] for c in t["columns"])
    for s in schema.get("sequences", []):
        if f'{s["name"]}' in used:       # identity/serial-owned sequences are created with their column
            cur.execute(f'create sequence public.{qi(s["name"])} as {s["type"]} start with {s["start"]} increment by {s["increment"]} '
                        f'minvalue {s["min"]} maxvalue {s["max"]}' + (" cycle" if s["cycle"] else ""))
    later = []
    for f in schema.get("functions", []):
        if _try(cur, f["def"]):
            later.append(f)               # signature mentions a table row type: create it after the tables
    for t in schema["tables"]:
        cur.execute(table_sql(t))
    for f in later:
        cur.execute(f["def"])
    rep["rebuilt"] = {"tables": len(schema["tables"]), "functions": len(schema.get("functions", [])), "roles_created_or_present": len(roles)}
    return skipped


def load_data(cur, schema: dict, data: dict, rep: dict):
    cur.execute("set session_replication_role = replica")     # no triggers, no FK checks while rows go in
    tdef = {t["name"]: t for t in schema["tables"]}
    loaded = {}
    for name, rows in data.items():
        t = tdef[name]
        cols = [c for c in t["columns"] if c.get("generated") != "s"]
        cl = ", ".join(qi(c["name"]) for c in cols)
        ov = " OVERRIDING SYSTEM VALUE" if any(c.get("identity") for c in t["columns"]) else ""
        for i in range(0, len(rows), 500):
            cur.execute(f'INSERT INTO public.{qi(name)} ({cl}){ov} SELECT {cl} FROM jsonb_populate_recordset(NULL::public.{qi(name)}, %s::jsonb)',
                        (json.dumps(rows[i:i + 500]),))
        loaded[name] = len(rows)
    cur.execute("set session_replication_role = origin")
    for s in schema.get("sequences", []):
        if s.get("last_value") is not None:
            cur.execute("select to_regclass(%s)", (f"public.{qi(s['name'])}",))
            if cur.fetchone()[0]:
                cur.execute("select setval(%s, %s)", (f"public.{qi(s['name'])}", s["last_value"]))
    # Sequences: never behind the data. Use the larger of the saved position and the highest id actually present in the owning column.
    for t in schema["tables"]:
        for c in t["columns"]:
            if c.get("identity") in ("a", "d") or "nextval(" in (c.get("default") or ""):
                cur.execute("select pg_get_serial_sequence(%s, %s)", (f"public.{qi(t['name'])}", c["name"]))
                seq = cur.fetchone()[0]
                if seq:
                    cur.execute(f"select coalesce(max({qi(c['name'])}), 0) from public.{qi(t['name'])}")
                    top = cur.fetchone()[0] or 0
                    cur.execute(f"select last_value from {seq}")
                    cur_val = cur.fetchone()[0]
                    if isinstance(top, int) and top > cur_val:
                        cur.execute("select setval(%s, %s)", (seq, top))
    rep["loaded_rows"] = sum(loaded.values())


def rebuild_constraints(cur, schema: dict, rep: dict):
    warnings = []
    for i in schema.get("indexes", []):      # first: a foreign key may rely on a plain unique index that is not itself a constraint
        cur.execute(i["def"])
    for kind in FK_LAST:
        for c in schema.get("constraints", []):
            if c["type"] != kind and not (kind == "x" and c["type"] not in FK_LAST):
                continue
            ddl = c["def"]
            if kind == "f" and "NOT VALID" not in ddl:
                cur.execute(f'ALTER TABLE public.{qi(c["table"])} ADD CONSTRAINT {qi(c["name"])} {ddl} NOT VALID')
                err = _try(cur, f'ALTER TABLE public.{qi(c["table"])} VALIDATE CONSTRAINT {qi(c["name"])}')
                if err:
                    warnings.append(f'{c["table"]}.{c["name"]}: rows violate this foreign key ({err[:90]})')
            else:
                cur.execute(f'ALTER TABLE public.{qi(c["table"])} ADD CONSTRAINT {qi(c["name"])} {ddl}')
    rep["constraint_warnings"] = warnings


def _acl_grants(entries) -> list:
    """['role=UC/grantor', ...] -> ['role:USAGE', 'role:CREATE'] (PUBLIC for an empty role; the owner's own entry is implicit and skipped)."""
    out = []
    for e in entries or []:
        e = str(e)
        if e.startswith('"'):                       # aclitem quotes role names containing spaces or quotes
            end = e.rfind('"=')
            who, rest = e[1:end].replace('""', '"'), e[end + 2:]
        else:
            who, _, rest = e.partition("=")
        privs = rest.split("/")[0]
        if who == "pg_database_owner":
            continue
        for ch, word in (("U", "USAGE"), ("C", "CREATE")):
            if ch in privs:
                out.append(f"{who or 'PUBLIC'}:{word}")
    return out


def replay_schema_acl_and_comments(cur, schema: dict, rep: dict) -> None:
    missing = []
    cur.execute("REVOKE ALL ON SCHEMA public FROM PUBLIC")     # a fresh database starts with PUBLIC USAGE; the snapshot decides, not the template
    for g in sorted(set(_acl_grants(schema.get("schema_acl")))):
        who, word = g.split(":")
        target = "PUBLIC" if who == "PUBLIC" else qi(who)
        if _try(cur, f"GRANT {word} ON SCHEMA public TO {target}"):
            missing.append(who)
    cur.execute("select current_setting('server_version_num')")
    for c in schema.get("comments") or []:
        text = c.get("text")
        if text is None:
            continue
        if c["kind"] == "column":
            obj = f'COLUMN public.{qi(c["name"])}.{qi(c["column"])}'
        elif c["kind"] == "function":
            if not re.fullmatch(r"[A-Za-z0-9_\"., ()\[\]]+", c["name"]):
                continue
            obj = f'FUNCTION {c["name"]}'
        else:
            word = {"table": "TABLE", "view": "VIEW", "matview": "MATERIALIZED VIEW", "sequence": "SEQUENCE"}[c["kind"]]
            obj = f'{word} public.{qi(c["name"])}'
        cur.execute("select quote_literal(%s)", (text,))
        _try(cur, f"COMMENT ON {obj} IS {cur.fetchone()[0]}")
    uns = schema.get("unsupported") or {}
    warn = {k: v for k, v in (("column_acls", uns.get("column_acls")), ("nondefault_owners", uns.get("nondefault_owners"))) if v}
    if warn or missing:
        rep.setdefault("not_restored", {}).update({**{k: f"{v} present in the source and NOT replayed" for k, v in warn.items()},
                                                   **({"schema_acl_roles_missing": sorted(set(missing))} if missing else {})})


def rebuild_rest(cur, schema: dict, rep: dict):
    for t in schema.get("triggers", []):
        cur.execute(t["def"])
        if t.get("enabled") in ("D", "A", "R"):
            word = {"D": "DISABLE", "A": "ENABLE ALWAYS", "R": "ENABLE REPLICA"}[t["enabled"]]
            cur.execute(f'ALTER TABLE public.{qi(t["table"])} {word} TRIGGER {qi(t["name"])}')
    pending = [v for v in schema.get("views", [])]
    for _ in range(5):                      # views may depend on each other: retry until stable
        nxt = []
        for v in pending:
            sql = (f'CREATE MATERIALIZED VIEW public.{qi(v["name"])} AS {v["def"].rstrip(";")}' if v["kind"] == "m"
                   else f'CREATE OR REPLACE VIEW public.{qi(v["name"])} AS {v["def"].rstrip(";")}')
            if _try(cur, sql):
                nxt.append(v)
        pending = nxt
        if not pending:
            break
    rep["views_failed"] = [v["name"] for v in pending]
    for v in schema.get("views", []):
        if v["kind"] == "v":
            for opt in v.get("options") or []:
                if re.fullmatch(r"[a-z_]+=[A-Za-z0-9_.]+", str(opt)):      # e.g. security_invoker=true; anything else is ignored, never executed
                    _try(cur, f'ALTER VIEW public.{qi(v["name"])} SET ({opt})')
    for t in schema["tables"]:
        if t.get("rls"):
            cur.execute(f'ALTER TABLE public.{qi(t["name"])} ENABLE ROW LEVEL SECURITY')
        if t.get("force_rls"):
            cur.execute(f'ALTER TABLE public.{qi(t["name"])} FORCE ROW LEVEL SECURITY')
    for p in schema.get("policies", []):
        roles = ", ".join(qi(r) if r.lower() != "public" else "PUBLIC" for r in (p.get("roles") or ["public"]))
        cur.execute(f'CREATE POLICY {qi(p["name"])} ON public.{qi(p["table"])} AS {p["permissive"]} FOR {p["cmd"]} TO {roles}'
                    + (f' USING ({p["using"]})' if p.get("using") else "") + (f' WITH CHECK ({p["check"]})' if p.get("check") else ""))
    # permissions: start from nothing for the roles involved, then replay exactly what the backup recorded
    cur.execute("select current_user")
    me = cur.fetchone()[0]
    names = {g["grantee"] for g in schema.get("table_grants", [])} | {"anon", "authenticated", "service_role"}
    for f in schema.get("functions", []):
        names.update(f.get("acl", []))
    names -= {"PUBLIC", "postgres", me}
    who = ", ".join(["PUBLIC"] + [qi(n) for n in sorted(names)])
    cur.execute(f"REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM {who}")
    # Only objects that carried explicit grants are touched: revoking on an object whose ACL was NULL would write an ACL it never had.
    for tbl, kind in sorted({(g["table"], g.get("kind")) for g in schema.get("table_grants", [])}):
        cur.execute(f'REVOKE ALL ON {"SEQUENCE" if kind == "S" else "TABLE"} public.{qi(tbl)} FROM {who}')
    for g in schema.get("table_grants", []):
        if g["grantee"] in ("postgres", me):
            continue
        obj = "SEQUENCE" if g.get("kind") == "S" else "TABLE"
        cur.execute(f'GRANT {g["privilege"]} ON {obj} public.{qi(g["table"])} TO ' + ("PUBLIC" if g["grantee"] == "PUBLIC" else qi(g["grantee"])))
    for f in schema.get("functions", []):
        for r in f.get("acl", []):
            if r not in ("postgres", me):
                cur.execute(f'GRANT EXECUTE ON FUNCTION {f["sig"]} TO ' + ("PUBLIC" if r == "PUBLIC" else qi(r)))
    ledger = schema.get("migration_ledger") or []
    if ledger:
        cur.execute("create schema if not exists supabase_migrations")
        cur.execute("create table supabase_migrations.schema_migrations (version text primary key, statements text[], name text)")
        for m in ledger:
            cur.execute("insert into supabase_migrations.schema_migrations values (%s, %s, %s)", (m["version"], m.get("statements"), m["name"]))
    rep["not_restored"] = {"cron_jobs": [j.get("jobname") for j in schema.get("cron", [])], "default_privileges_for_future_objects": len(schema.get("default_privileges", [])),
                           "note": "cron jobs and default privileges are recorded in schema.json but not replayed; recreate cron jobs on the real project after a restore"}


# ------------------------------------------------------------------ verify the result

TS = re.compile(r"^\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d(:?\d\d)?)$")


def canon(v):
    if isinstance(v, dict):
        return {k: canon(x) for k, x in sorted(v.items())}
    if isinstance(v, list):
        return [canon(x) for x in v]
    if isinstance(v, bool):
        return v
    if isinstance(v, int):
        return "N:" + str(v)
    if isinstance(v, float):
        v = Decimal(repr(v))
    if isinstance(v, Decimal):
        return "N:" + format(v.normalize(), "f") if v != v.to_integral_value() else "N:" + str(int(v))
    if isinstance(v, str) and TS.match(v):
        try:
            d = dt.datetime.fromisoformat(v.replace("Z", "+00:00"))
            return "T:" + d.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")
        except ValueError:
            return v
    return v


def canon_line(obj) -> str:
    return json.dumps(canon(obj), sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def verify_rows(cur, data: dict, rep: dict) -> bool:
    ok, out = True, {}
    cur.execute("set time zone 'UTC'")
    for t, rows in data.items():
        src = collections.Counter(canon_line(json.loads(json.dumps(r), parse_float=Decimal)) for r in rows)
        cur.execute(f"select count(*) from public.{qi(t)}")
        n = cur.fetchone()[0]
        got = collections.Counter()
        with cur.connection.cursor(name=f"v_{t}"[:60]) as sc:
            sc.itersize = 2000
            sc.execute(f"select to_jsonb(x)::text from public.{qi(t)} x")
            for (txt,) in sc:
                got[canon_line(json.loads(txt, parse_float=Decimal))] += 1
        missing, extra = sum((src - got).values()), sum((got - src).values())
        good = (n == len(rows) and not missing and not extra)
        ok &= good
        out[t] = {"backup_rows": len(rows), "restored_rows": n, "identical": good, **({} if good else {"missing_in_restore": missing, "unexpected_in_restore": extra})}
    rep["rows"] = out
    return ok


COMPARE = ("tables", "constraints", "indexes", "triggers", "functions", "views", "policies", "table_grants", "sequences", "enums", "domains", "comments", "schema_acl")


def _norm(cat, items):
    if cat == "functions":
        return sorted((f["sig"], f["md5"], tuple(sorted(f.get("acl", [])))) for f in items)
    if cat == "sequences":
        return sorted((s["name"], s["type"], s["start"], s["increment"], s["min"], s["max"], s["cycle"]) for s in items)
    if cat == "schema_acl":
        return sorted(_acl_grants(items))
    if cat == "tables":
        return sorted(json.dumps(t, sort_keys=True) for t in items)
    return sorted(json.dumps(i, sort_keys=True) for i in items)


def verify_schema(cur, schema: dict, rep: dict) -> bool:
    cur.execute("select public.backup_schema()")
    now = cur.fetchone()[0]
    ok, out = True, {}
    for cat in COMPARE:
        a, b = _norm(cat, schema.get(cat, [])), _norm(cat, now.get(cat, []))
        same = a == b
        ok &= same
        entry = {"backup": len(a), "restored": len(b), "identical": same}
        if not same:
            sa, sb = set(map(str, a)), set(map(str, b))
            entry["only_in_backup"] = [x[:140] for x in sorted(sa - sb)[:3]]
            entry["only_in_restore"] = [x[:140] for x in sorted(sb - sa)[:3]]
        out[cat] = entry
    rep["schema"] = out
    return ok


def smoke(cur, rep: dict) -> bool:
    res, ok = {}, True
    def attempt(name, sql, expect_error=None):
        nonlocal ok
        cur.execute("savepoint sm")
        try:
            cur.execute(sql)
            r = cur.fetchone() if cur.description else None
            res[name] = {"ok": expect_error is None, "result": str(r)[:80] if r else None} if expect_error is None else {"ok": False, "detail": "expected an error but it ran"}
        except Exception as e:
            msg = str(e).split("\n")[0]
            res[name] = {"ok": bool(expect_error and expect_error in msg), "detail": msg[:100]}
        ok &= res[name]["ok"]
        cur.execute("rollback to savepoint sm")
    attempt("capital_mode() runs", "select public.capital_mode()")
    cur.execute("update public.system_state set kill_switch = true where id = 1")
    attempt("spend gateway refuses when kill switch is on", "select public.reserve_llm_budget('jarvis', 1, 'claude-haiku-5-5', 'restore smoke test')", expect_error="Kill switch is on")
    cur.execute("update public.system_state set kill_switch = false where id = 1")
    rep["smoke"] = res
    return ok


CATEGORIES = {"Tasks and missions": ["tasks", "missions"], "Leads and outbox drafts": ["leads", "outbox"], "Company memory": ["memory", "company_profile", "handbook"],
              "Spending ledger and LLM calls": ["ledger", "llm_calls", "spend_reservations", "capital_policy"], "Audit logs": ["audit_log", "action_log"]}


def summarize(rep: dict) -> None:
    rows = rep.get("rows", {})
    cat = {}
    for name, tabs in CATEGORIES.items():
        pr = [t for t in tabs if t in rows]
        cat[name] = {"tables": {t: f'{rows[t]["backup_rows"]} -> {rows[t]["restored_rows"]}' for t in pr}, "all_identical": all(rows[t]["identical"] for t in pr) and bool(pr)}
    rep["business_data"] = cat


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--file"); ap.add_argument("--sidecar"); ap.add_argument("--b2-latest", action="store_true"); ap.add_argument("--b2-name")
    ap.add_argument("--list", action="store_true"); ap.add_argument("--target"); ap.add_argument("--wipe", action="store_true")
    ap.add_argument("--verify-only", action="store_true"); ap.add_argument("--expect-sha256"); ap.add_argument("--report")
    args = ap.parse_args()
    if not (args.file or args.b2_latest or args.b2_name or args.list):
        ap.error("give --file, --b2-latest, --b2-name or --list")
    rep = {"started_utc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "steps": {}}
    code = 0
    try:
        enc, side, name = fetch(args)
        manifest, schema, data = open_archive(enc, side, name, args.expect_sha256, rep)
        rep["steps"]["file_checksum_decrypt_manifest"] = "PASS"
        if args.verify_only:
            pass
        else:
            if not schema:
                raise Fail("this backup has no schema.json (data-only); it cannot be restored to a working database by this tool")
            import psycopg2
            dsn = args.target or os.environ.get("RESTORE_DB_URL") or ""
            if not dsn:
                raise Fail("set RESTORE_DB_URL (or --target) to a scratch database")
            scrub_environment()
            rep["target"] = assert_scratch(dsn)
            conn = psycopg2.connect(dsn)
            conn.autocommit = False
            cur = conn.cursor()
            assert_not_supabase(cur)
            cur.execute("select count(*) from pg_tables where schemaname='public'")
            if cur.fetchone()[0]:
                if not args.wipe:
                    raise Fail("the scratch database is not empty; add --wipe to drop its public schema first")
                cur.execute("drop schema public cascade"); cur.execute("drop schema if exists supabase_migrations cascade"); cur.execute("create schema public")
            cur.execute("set time zone 'UTC'")
            skipped = rebuild_schema(cur, schema, rep); rep["steps"]["schema_rebuilt"] = "PASS"
            load_data(cur, schema, data, rep); rep["steps"]["data_loaded"] = "PASS"
            rebuild_constraints(cur, schema, rep); rebuild_rest(cur, schema, rep); replay_schema_acl_and_comments(cur, schema, rep)
            rep["steps"]["constraints_indexes_triggers_views_policies_grants"] = "PASS" if not rep["views_failed"] else "FAIL"
            rep.setdefault("not_restored", {}).update(dict(skipped))
            conn.commit()
            checks = [("every_row_identical", verify_rows(cur, data, rep)), ("schema_identical", verify_schema(cur, schema, rep)), ("smoke_tests", smoke(cur, rep))]
            conn.rollback()      # smoke tests changed nothing that persists
            for k, v in checks:
                rep["steps"][k] = "PASS" if v else "FAIL"
            summarize(rep)
            led = len(schema.get("migration_ledger") or [])
            rep["migration_ledger_rows"] = led
            if not all(v for _, v in checks) or rep["views_failed"]:
                code = 1
            elif rep.get("constraint_warnings"):
                code = 4          # data restored and identical, but some rows violate foreign keys: not a clean recovery
                rep["note"] = "foreign-key violations present in the backed-up data"
    except Fail as e:
        rep["error"] = str(e); code = 2
    except Exception as e:                      # never print connection strings or keys
        rep["error"] = f"{type(e).__name__}: {str(e).splitlines()[0][:160] if str(e) else ''}"; code = 3
    rep["result"] = "PASS" if code == 0 else ("PASS_WITH_WARNINGS" if code == 4 else "FAIL")
    text = json.dumps(rep, indent=2, default=str)
    if args.report:
        open(args.report, "w").write(text)
    print(text)
    sys.exit(code)


if __name__ == "__main__":
    main()
