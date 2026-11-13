"""Encrypted, checksummed, off-site backup of the HQ database. DORMANT until BACKUP_KEY (a Fernet key) and BACKUP_PUT_URL are set in Railway.

What a backup contains (format 2), all inside one Fernet-encrypted gzip tar:
  manifest.json      format, time, engine build, per-table row counts + sha256, schema digest, "complete" flag
  schema.json        the output of public.backup_schema(): every table, column, constraint, index, trigger, function, view, grant, ...
  data/<table>.jsonl one JSON object per row, every table in the schema except the secret-bearing ones in SKIP
Next to the encrypted file a plain "<name>.sha256" (sha256sum format) is stored, so the file can be checked without the key.

Targets (BACKUP_PUT_URL):
  b2://<bucketId>[/prefix]   Backblaze B2 native API. BACKUP_AUTH = "<applicationKeyId>:<applicationKey>". Recommended: a key limited to ONE
                             bucket with only listFiles + writeFiles (it can add backups but cannot delete them). B2 itself checks the SHA-1.
  https://host/path/{name}   any server that accepts an HTTP PUT (WebDAV etc.); BACKUP_AUTH, if set, is sent as the Authorization header.
Put the backup somewhere that is NOT this Supabase project, or one outage takes both.

Secrets: the key, the auth value and any token are read from the environment only and are never logged, audited, or put in an error message.
The restore side is ops/restore_backup.py (separate implementation, so a bug here cannot hide a bad backup)."""
import base64, hashlib, io, json, logging, os, re, tarfile, threading, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import hq

logger = logging.getLogger(__name__)

FORMAT = 2
SKIP = {"push_config", "push_subscriptions"}   # hold private keys / endpoints: never exported
# Used only when public.backup_schema() is not installed yet. With the function present the table list comes from the database itself,
# so a table added later cannot be silently left out.
TABLES = ["departments", "deals", "audit_log", "build_requests", "company_profile", "dayjob_days", "dayjob_targets", "agents",
          "accounts_registry", "handbook", "ledger", "ideas", "escalations", "leads", "human_handoffs", "owner_messages", "model_prices",
          "predictions", "tool_registry", "reconciliation_flags", "tasks", "systems", "llm_calls", "ventures", "memory", "outbox",
          "system_state", "missions", "agent_runs", "action_policy", "action_log", "approval_requests", "capital_policy",
          "spend_reservations", "bank_accounts", "bank_balances", "bank_transactions", "mission_outcomes", "org_changes", "venture_goals",
          "app_owners", "web_messages", "payment_instructions", "venture_assets", "venture_procedures", "account_requests",
          "setter_terms", "setters", "setter_events", "setter_payouts", "waterfall_policy", "integration_status", "alert_state"]
ORDER = {"company_profile": "venture_slug", "departments": "slug", "agents": "slug", "app_owners": "email", "dayjob_days": "day",
         "tool_registry": "slug", "systems": "name", "action_policy": "action", "model_prices": "model", "setters": "id",
         "integration_status": "key", "alert_state": "key"}
PAGE = 1000
MAX_ROWS_PER_TABLE = 500_000

B2_AUTH_URL = "https://api.backblazeb2.com/b2api/v4/b2_authorize_account"
B2_HOST_SUFFIXES = (".backblazeb2.com", ".backblaze.com")   # every URL B2 hands back (api, upload pods) must be https on a Backblaze domain, or we refuse to send data to it
_B2_PATH = "/b2api/v4/"
_NO_SLEEP = False   # tests set this so retry backoff does not slow them down


class BackupError(Exception):
    """A failure whose message is safe to log and to tell the owner (never contains a secret)."""


def configured() -> bool:
    return bool(os.environ.get("BACKUP_KEY") and os.environ.get("BACKUP_PUT_URL"))


def _fernet():
    from cryptography.fernet import Fernet
    return Fernet(os.environ["BACKUP_KEY"].encode())


# ------------------------------------------------------------------ dump

def get_schema() -> dict | None:
    """The live schema description, or None when public.backup_schema() is not installed (old database)."""
    try:
        s = hq._request("POST", "/rest/v1/rpc/backup_schema", {}, timeout=60)
    except urllib.error.HTTPError as e:
        if e.code == 404:        # PostgREST: function not found (PGRST202) = migration not applied. Any other error must NOT silently downgrade the backup.
            return None
        raise
    if not isinstance(s, dict) or not s.get("tables"):
        raise BackupError("backup_schema() returned an unexpected result")
    return s


def _pk_order(schema: dict | None, table: str) -> str:
    if schema:
        for c in schema.get("constraints", []):
            if c.get("table") == table and c.get("type") == "p":
                m = re.search(r"PRIMARY KEY \((.*)\)", c.get("def", ""))
                if m:
                    cols = [x.strip().strip('"') for x in m.group(1).split(",")]
                    if all(re.fullmatch(r"[a-z_][a-z0-9_]*", x) for x in cols):
                        return "&order=" + ",".join(f"{x}.asc" for x in cols)
    return f"&order={ORDER.get(table, 'id')}.asc"


def _read_table(t: str, schema: dict | None) -> list:
    """Page until an EMPTY page, advancing by what was actually returned, so a server-side row cap below PAGE cannot drop rows."""
    rows, off = [], 0
    order, unordered = _pk_order(schema, t), False
    while off < MAX_ROWS_PER_TABLE:
        try:
            page = hq._request("GET", f"/rest/v1/{t}?select=*{order}&limit={PAGE}&offset={off}", exact=True) or []
        except urllib.error.HTTPError as e:
            if e.code != 400 or not order:   # no such sort column: unordered paging is only safe when everything fits in one page
                raise
            order, unordered = "", True
            page = hq._request("GET", f"/rest/v1/{t}?select=*&limit={PAGE}&offset={off}", exact=True) or []
        if not page:
            return rows
        rows.extend(page)
        if unordered and (off > 0 or len(page) >= PAGE):
            raise BackupError(f"{t}: cannot page a large table without a sort key")
        off += len(page)
    raise BackupError(f"{t}: more than {MAX_ROWS_PER_TABLE} rows; refusing to write a partial backup")


_DEC = re.compile(r'"\\u0000DEC:(-?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)"')


def row_json(r: dict) -> str:
    """One row as compact JSON. Decimal values are written exactly as the database sent them (30.00 stays 30.00; no float rounding)."""
    def enc(o):
        if isinstance(o, Decimal):
            return ("\u0000DEC:" + str(o)) if o.is_finite() else str(o)
        return str(o)
    return _DEC.sub(r"\1", json.dumps(r, default=enc, separators=(",", ":"), sort_keys=True))


def _add(tar: tarfile.TarFile, name: str, data: bytes) -> None:
    info = tarfile.TarInfo(name=name); info.size = len(data); info.mtime = 0
    tar.addfile(info, io.BytesIO(data))


CONSISTENCY_ATTEMPTS = 3


def _read_all(names, schema) -> dict:
    """One pass over every table: {table: (jsonl bytes, row count)}."""
    out = {}
    for t in names:
        rows = _read_table(t, schema)
        out[t] = (("\n".join(row_json(r) for r in rows)).encode(), len(rows))
    return out


def _read_consistent(names, schema) -> tuple[dict, dict]:
    """The REST API cannot give one transaction across requests, so read every table twice and accept only when both passes
    are byte-identical (nothing changed anywhere while we were reading). Retries a few times; if the data keeps moving the
    backup is still made but is flagged consistent=False so the owner knows and the restore tool warns."""
    first = _read_all(names, schema)
    for attempt in range(1, CONSISTENCY_ATTEMPTS + 1):
        second = _read_all(names, schema)
        moved = sorted(t for t in names if hashlib.sha256(first[t][0]).digest() != hashlib.sha256(second[t][0]).digest())
        if not moved:
            return second, {"consistent": True, "method": "two identical full reads", "attempts": attempt}
        first = second
    return second, {"consistent": False, "method": "two identical full reads", "attempts": CONSISTENCY_ATTEMPTS, "changing_tables": moved[:10]}


def dump() -> tuple[bytes, dict]:
    """Returns (plain tar.gz bytes, manifest). Raises if any table cannot be read completely."""
    schema = get_schema()
    names = [t["name"] for t in schema["tables"]] if schema else list(TABLES)
    names = [t for t in names if t not in SKIP]
    manifest = {"format": FORMAT, "created_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "engine_build": (os.environ.get("RAILWAY_GIT_COMMIT_SHA") or os.environ.get("GIT_COMMIT") or "unknown")[:40],
                "skipped": sorted(SKIP), "tables": {}, "schema": None,
                "table_list_source": "database" if schema else "built-in list (backup_schema() not installed)"}
    data_by_table, manifest["consistency"] = _read_consistent(names, schema)
    if schema:
        # Read the schema AGAIN after the data: sequence positions must not be older than the rows we saved (a restored sequence behind the
        # data would hand out ids that already exist). If the table list changed while we were reading, refuse: tomorrow's run starts clean.
        after = get_schema()
        if not after or sorted(t["name"] for t in after["tables"]) != sorted(t["name"] for t in schema["tables"]):
            raise BackupError("tables were added or removed while the backup was being read; will retry later")
        schema = after
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for t in names:
            data, n = data_by_table[t]
            _add(tar, f"data/{t}.jsonl", data)
            manifest["tables"][t] = {"rows": n, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        if schema:
            sdata = json.dumps(schema, separators=(",", ":"), sort_keys=True, default=str).encode()
            _add(tar, "schema.json", sdata)
            manifest["schema"] = {"sha256": hashlib.sha256(sdata).hexdigest(), "bytes": len(sdata), "server_version": schema.get("server_version"),
                                  "counts": {k: len(v) for k, v in schema.items() if isinstance(v, list)}}
        manifest["total_rows"] = sum(v["rows"] for v in manifest["tables"].values())
        manifest["complete"] = bool(schema)    # data of every table AND the schema; False = data only (see "table_list_source")
        _add(tar, "manifest.json", json.dumps(manifest, separators=(",", ":"), sort_keys=True).encode())
    return buf.getvalue(), manifest


def encrypt(blob: bytes) -> bytes:
    return _fernet().encrypt(blob)


def verify(encrypted: bytes, manifest: dict) -> list[str]:
    """Decrypt and recheck every member against the manifest. Returns a list of problems (empty = readable and intact)."""
    problems = []
    try:
        plain = _fernet().decrypt(encrypted)
        with tarfile.open(fileobj=io.BytesIO(plain), mode="r:gz") as tar:
            stored = json.loads(tar.extractfile("manifest.json").read())
            if stored != manifest:
                problems.append("manifest inside the file differs from the one that was built")
            for t, meta in manifest["tables"].items():
                f = tar.extractfile(f"data/{t}.jsonl")
                raw = b"" if f is None else f.read()
                got = len([ln for ln in raw.decode().split("\n") if ln.strip()])
                if got != meta["rows"]:
                    problems.append(f"{t}: expected {meta['rows']} rows, found {got}")
                if hashlib.sha256(raw).hexdigest() != meta["sha256"]:
                    problems.append(f"{t}: checksum differs")
            if manifest.get("schema"):
                f = tar.extractfile("schema.json")
                if f is None or hashlib.sha256(f.read()).hexdigest() != manifest["schema"]["sha256"]:
                    problems.append("schema.json checksum differs")
    except Exception as e:
        problems.append(f"cannot read backup: {type(e).__name__}")
    return problems


# ------------------------------------------------------------------ upload

def _call(method: str, url: str, headers: dict, body: bytes | None = None, timeout: int = 120) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.read()
        except Exception:
            return e.code, b""


def _b2_ok_url(url: str) -> bool:
    p = urllib.parse.urlparse(url)
    h = p.hostname or ""
    return p.scheme == "https" and any(h.endswith(x) or h == x[1:] for x in B2_HOST_SUFFIXES)


def _b2_error(what: str, status: int, body: bytes) -> BackupError:
    code = ""
    try:
        code = str(json.loads(body).get("code", ""))[:40]
    except Exception:
        pass
    return BackupError(f"B2 {what} failed (HTTP {status}{' ' + code if code else ''})")


def b2_parse(url: str) -> tuple[str, str]:
    m = re.fullmatch(r"b2://([A-Za-z0-9]{8,64})(?:/(.*))?", url or "")
    if not m:
        raise BackupError("BACKUP_PUT_URL for B2 must look like b2://<bucketId>[/prefix]")
    prefix = (m.group(2) or "").strip("/")
    return m.group(1), (prefix + "/") if prefix else ""


def _b2_authorize_raw(auth: str) -> dict:
    if ":" not in (auth or ""):
        raise BackupError("BACKUP_AUTH for B2 must be applicationKeyId:applicationKey")
    cred = base64.b64encode(auth.encode()).decode()
    status, body = _call("GET", B2_AUTH_URL, {"Authorization": f"Basic {cred}"}, timeout=30)
    if status != 200:
        raise _b2_error("authorize", status, body)
    j = json.loads(body)
    api = ((j.get("apiInfo") or {}).get("storageApi") or {}).get("apiUrl") or j.get("apiUrl")
    if not api or not j.get("authorizationToken") or not _b2_ok_url(api):
        raise BackupError("B2 authorize returned an unexpected response")
    j["_api"] = api
    return j


def b2_authorize(auth: str) -> tuple[str, str]:
    """Returns (authorizationToken, apiUrl). The key never appears in an error."""
    j = _b2_authorize_raw(auth)
    return j["authorizationToken"], j["_api"]


def preflight() -> list[dict]:
    """Read-only configuration check for /backup check. Never uploads, never prints a secret, only names and pass/warn/fail."""
    out = []
    def add(name, status, detail=""):
        out.append({"check": name, "status": status, "detail": detail})
    env = os.environ
    for v in ("BACKUP_KEY", "BACKUP_PUT_URL", "BACKUP_AUTH"):
        add(f"{v} is set", "pass" if env.get(v) else "fail")
    key_ok = False
    if env.get("BACKUP_KEY"):
        try:
            f = _fernet(); key_ok = f.decrypt(f.encrypt(b"x")) == b"x"
        except Exception:
            key_ok = False
        add("BACKUP_KEY is a valid encryption key (encrypt/decrypt round trip)", "pass" if key_ok else "fail",
            "" if key_ok else "must be a Fernet key: 44 characters ending in =")
    bucket = None
    url = env.get("BACKUP_PUT_URL", "")
    if url.startswith("b2://"):
        try:
            bucket, prefix = b2_parse(url); add("BACKUP_PUT_URL format (b2://<bucketId>/hq)", "pass")
        except BackupError as e:
            add("BACKUP_PUT_URL format (b2://<bucketId>/hq)", "fail", str(e))
    elif url:
        add("BACKUP_PUT_URL contains {name}", "pass" if ("{name}" in url and url.startswith("https://")) else "fail", "generic https target in use; B2 checks skipped")
    if bucket and env.get("BACKUP_AUTH"):
        try:
            j = _b2_authorize_raw(env["BACKUP_AUTH"]); add("Backblaze accepts the application key", "pass")
            allowed = ((j.get("apiInfo") or {}).get("storageApi") or {}).get("allowed") or j.get("allowed") or {}
            caps = set(allowed.get("capabilities") or [])
            limited = [b.get("id") for b in (allowed.get("buckets") or []) if b.get("id")] or ([allowed["bucketId"]] if allowed.get("bucketId") else [])
            add("Key can write files", "pass" if "writeFiles" in caps else "fail", "" if "writeFiles" in caps else "key needs writeFiles")
            if limited:
                same = limited == [bucket]
                add("Key is limited to the backup bucket", "pass" if same else "fail", "" if same else "key is limited to a different bucket than BACKUP_PUT_URL")
            else:
                add("Key is limited to the backup bucket", "warn", "key can reach every bucket; create a key restricted to one bucket")
            extra = sorted(caps & {"deleteFiles", "readFiles", "deleteKeys", "writeKeys", "writeBuckets", "deleteBuckets"})
            add("Key has no delete/read/admin powers (bot key should be write-only)", "pass" if not extra else "warn",
                "" if not extra else "extra capabilities: " + ", ".join(extra))
            pfx = allowed.get("namePrefix")
            if pfx and not prefix.startswith(pfx):
                add("Key file-name prefix matches BACKUP_PUT_URL prefix", "fail", "key is limited to a different prefix")
            st, body = _call("POST", f"{j['_api']}{_B2_PATH}b2_get_upload_url", {"Authorization": j["authorizationToken"], "Content-Type": "application/json"},
                             json.dumps({"bucketId": bucket}).encode(), timeout=30)
            add("Backblaze issues an upload address for the bucket", "pass" if st == 200 else "fail", "" if st == 200 else str(_b2_error("get_upload_url", st, body)))
        except BackupError as e:
            add("Backblaze accepts the application key", "fail", str(e))
        except Exception as e:
            add("Backblaze accepts the application key", "fail", type(e).__name__)
    try:
        sch = get_schema()
        add("Database schema snapshot function (backup_schema) installed", "pass" if sch else "warn", "" if sch else "not installed; backups would be data-only")
    except Exception as e:
        add("Database reachable", "fail", type(e).__name__)
    return out


def b2_put(name: str, data: bytes, bucket_id: str, prefix: str, token: str, api: str) -> dict:
    """Upload one file. B2's guidance: on a network error, a 5xx/408/429 or an expired token (401), fetch a NEW upload URL and try again."""
    sha1 = hashlib.sha1(data).hexdigest()
    last = None
    for attempt in range(5):
        try:
            status, body = _call("POST", f"{api}{_B2_PATH}b2_get_upload_url", {"Authorization": token, "Content-Type": "application/json"},
                                 json.dumps({"bucketId": bucket_id}).encode(), timeout=30)
            if status != 200:
                last = _b2_error("get_upload_url", status, body)
                if status in (408, 429) or status >= 500:
                    time.sleep(min(2 ** attempt, 8) if not _NO_SLEEP else 0); continue
                raise last
            up = json.loads(body)
            if not _b2_ok_url(up.get("uploadUrl", "")):
                raise BackupError("B2 returned an unexpected upload address")
            status, body = _call("POST", up["uploadUrl"], {
                "Authorization": up["authorizationToken"], "X-Bz-File-Name": urllib.parse.quote(prefix + name, safe="/"),
                "Content-Type": "application/octet-stream", "X-Bz-Content-Sha1": sha1, "Content-Length": str(len(data))}, data)
        except BackupError:
            raise
        except (urllib.error.URLError, OSError):
            last = BackupError("B2 upload failed (network error)")
            time.sleep(min(2 ** attempt, 8) if not _NO_SLEEP else 0); continue
        if status == 200:
            j = json.loads(body)
            if str(j.get("contentSha1", "")).lower() != sha1 or int(j.get("contentLength", -1)) != len(data):
                raise BackupError("B2 stored a different size or checksum than was sent")
            return {"file_id": j.get("fileId"), "bytes": len(data), "sha1": sha1}
        last = _b2_error("upload", status, body)
        if status in (401, 408, 429) or status >= 500:
            time.sleep(min(2 ** attempt, 8) if not _NO_SLEEP else 0); continue
        break
    raise last


def put_files(files: dict[str, bytes]) -> dict:
    """Upload every file ({name: bytes}) to the configured target. Raises BackupError on any failure; returns non-secret details."""
    url = os.environ["BACKUP_PUT_URL"]
    if url.startswith("b2://"):
        bucket, prefix = b2_parse(url)
        token, api = b2_authorize(os.environ.get("BACKUP_AUTH", ""))
        return {"target": "b2", "files": {n: b2_put(n, d, bucket, prefix, token, api) for n, d in files.items()}}
    if not url.startswith("https://"):
        raise BackupError("BACKUP_PUT_URL must be https:// or b2://")
    if "{name}" not in url:
        raise BackupError("BACKUP_PUT_URL must contain {name}, otherwise the backup and its checksum file would overwrite each other")
    headers = {"Content-Type": "application/octet-stream"}
    if os.environ.get("BACKUP_AUTH"):
        headers["Authorization"] = os.environ["BACKUP_AUTH"]
    out = {}
    for n, d in files.items():
        status, _ = _call("PUT", url.replace("{name}", urllib.parse.quote(n, safe="")), headers, d)
        if not 200 <= status < 300:
            raise BackupError(f"upload of {n} failed (HTTP {status})")
        out[n] = {"bytes": len(d)}
    return {"target": "put", "files": out}


def upload(name: str, encrypted: bytes) -> bool:
    """Single-file upload kept for callers/tests that only need success or failure."""
    try:
        put_files({name: encrypted})
        return True
    except (BackupError, urllib.error.URLError, OSError, ValueError, KeyError):
        return False


# ------------------------------------------------------------------ run

def _audit(action: str, detail: dict) -> None:
    try:
        hq._request("POST", "/rest/v1/audit_log", {"actor": "system", "action": action, "target": "backup", "detail": detail}, prefer="return=minimal")
    except Exception:
        pass


RETRY_GAP_MIN = 90        # after a failed attempt, wait this long before trying again
MAX_FAILURES_PER_DAY = 3   # ... and stop for the day after this many failures


def _recent_failures(now: datetime) -> list:
    since = (now - timedelta(hours=20)).isoformat()
    return hq._request("GET", f"/rest/v1/audit_log?action=eq.backup_failed&at=gte.{urllib.parse.quote(since)}&select=at&order=at.desc&limit=10") or []


def due(now: datetime | None = None) -> bool:
    """One run a day, in the quiet window 02:00-05:00 Toronto, only if none succeeded in the last 20 hours, with a retry gap and a daily cap
    on failures (so a persistent fault cannot cause a dump and a message every 5 minutes)."""
    from zoneinfo import ZoneInfo
    now = now or datetime.now(timezone.utc)
    if not 2 <= now.astimezone(ZoneInfo("America/Toronto")).hour < 5:
        return False
    since = (now - timedelta(hours=20)).isoformat()
    rows = hq._request("GET", f"/rest/v1/audit_log?action=eq.backup_ok&at=gte.{urllib.parse.quote(since)}&select=id&limit=1") or []
    if rows:
        return False
    fails = _recent_failures(now)
    if len(fails) >= MAX_FAILURES_PER_DAY:
        return False
    if fails:
        last = datetime.fromisoformat(str(fails[0]["at"]).replace("Z", "+00:00"))
        if last.tzinfo is None:
            last = last.replace(tzinfo=timezone.utc)
        if now - last < timedelta(minutes=RETRY_GAP_MIN):
            return False
    return True


def last_ok() -> dict | None:
    """The most recent successful backup's audit detail (file, bytes, sha256, rows, ...), for /backup status."""
    try:
        rows = hq._request("GET", "/rest/v1/audit_log?action=eq.backup_ok&select=at,detail&order=at.desc&limit=1") or []
        return {"at": rows[0]["at"], **rows[0]["detail"]} if rows else None
    except Exception:
        return None


_RUN_LOCK = threading.Lock()


def _tell_owner(body: str) -> None:
    """Best effort. A failed notification must never turn a good backup into a reported failure."""
    try:
        hq._request("POST", "/rest/v1/owner_messages", {"from_agent": "jarvis", "kind": "info", "channel": "telegram", "body": body}, prefer="return=minimal")
    except Exception:
        logger.warning("backup: owner message not delivered")


def run(force: bool = False) -> dict:
    """Make, verify and upload one backup. Never raises. A failure is logged, and the owner is told once per day."""
    out = {"ok": False, "reason": None}
    if not _RUN_LOCK.acquire(blocking=False):
        out["reason"] = "a backup is already running"; return out
    try:
        if not configured():
            out["reason"] = "not configured"; return out
        if not force:
            try:
                if not due():
                    out["reason"] = "not due"; return out
            except Exception:
                out["reason"] = "could not read backup state"; return out
        try:
            blob, manifest = dump()
            enc = encrypt(blob)
            problems = verify(enc, manifest)
            if problems:
                raise BackupError("self-check failed: " + "; ".join(problems[:3]))
            digest = hashlib.sha256(enc).hexdigest()
            name = f"hq-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.tar.gz.enc"
            put = put_files({name: enc, name + ".sha256": f"{digest}  {name}\n".encode()})
        except Exception as e:
            msg = str(e) if isinstance(e, BackupError) else type(e).__name__   # only our own messages are known to be secret-free
            out["reason"] = msg[:200]
            first_today = True
            try:
                first_today = not _recent_failures(datetime.now(timezone.utc))
            except Exception:
                pass
            _audit("backup_failed", {"error": out["reason"]})
            if first_today:
                _tell_owner(f"Backup failed: {out['reason']}. Your data is safe in the database. I retry automatically (at most {MAX_FAILURES_PER_DAY} tries tonight) and will not repeat this message today.")
            return out
        # The file is safely off-site and verified. Nothing after this point may turn it into a "failure".
        detail = {"file": name, "bytes": len(enc), "sha256": digest, "rows": manifest["total_rows"], "tables": len(manifest["tables"]),
                  "complete": manifest["complete"], "consistent": manifest["consistency"]["consistent"], "format": FORMAT, "target": put["target"],
                  "build": manifest["engine_build"][:12], "b2_file_id": (put["files"].get(name) or {}).get("file_id")}
        out.update(ok=True, file=name, rows=manifest["total_rows"], sha256=digest, complete=manifest["complete"])
        try:
            _audit("backup_ok", detail)
        except Exception:
            out["reason"] = "uploaded, but the audit row could not be written"
            logger.warning("backup: audit row not written")
        if not manifest["consistency"]["consistent"]:
            _tell_owner("Backup saved, but the data was changing while it was read, so tables may be slightly out of step with each other. Tomorrow's backup will try again.")
        if not manifest["complete"]:
            _tell_owner("Backup saved, but it holds data only: the schema snapshot function is not installed in the database yet. Ask for the backup_schema migration.")
    finally:
        _RUN_LOCK.release()
    return out
