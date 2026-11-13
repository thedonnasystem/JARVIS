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
import base64, hashlib, io, json, os, re, tarfile, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import hq

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
B2_HOST_SUFFIX = ".backblazeb2.com"     # every URL B2 hands back must be https on this domain, or we refuse to send data to it
_B2_PATH = "/b2api/v4/"


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
        return s if isinstance(s, dict) and s.get("tables") else None
    except Exception:
        return None


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
    rows, off = [], 0
    order = _pk_order(schema, t)
    while off < MAX_ROWS_PER_TABLE:
        try:
            page = hq._request("GET", f"/rest/v1/{t}?select=*{order}&limit={PAGE}&offset={off}", exact=True) or []
        except urllib.error.HTTPError as e:
            if e.code != 400 or not order:   # no such sort column: fall back to unordered paging (small tables)
                raise
            order = ""
            page = hq._request("GET", f"/rest/v1/{t}?select=*&limit={PAGE}&offset={off}", exact=True) or []
        rows.extend(page)
        if len(page) < PAGE:
            return rows
        off += PAGE
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


def dump() -> tuple[bytes, dict]:
    """Returns (plain tar.gz bytes, manifest). Raises if any table cannot be read completely."""
    schema = get_schema()
    names = [t["name"] for t in schema["tables"]] if schema else list(TABLES)
    names = [t for t in names if t not in SKIP]
    manifest = {"format": FORMAT, "created_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "engine_build": (os.environ.get("RAILWAY_GIT_COMMIT_SHA") or os.environ.get("GIT_COMMIT") or "unknown")[:40],
                "skipped": sorted(SKIP), "tables": {}, "schema": None,
                "table_list_source": "database" if schema else "built-in list (backup_schema() not installed)"}
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for t in names:
            rows = _read_table(t, schema)
            data = ("\n".join(row_json(r) for r in rows)).encode()
            _add(tar, f"data/{t}.jsonl", data)
            manifest["tables"][t] = {"rows": len(rows), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
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
    return p.scheme == "https" and bool(p.hostname) and (p.hostname.endswith(B2_HOST_SUFFIX) or p.hostname == B2_HOST_SUFFIX[1:])


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


def b2_authorize(auth: str) -> tuple[str, str]:
    """Returns (authorizationToken, apiUrl). The key never appears in an error."""
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
    return j["authorizationToken"], api


def b2_put(name: str, data: bytes, bucket_id: str, prefix: str, token: str, api: str) -> dict:
    sha1 = hashlib.sha1(data).hexdigest()
    last = None
    for _ in range(3):   # B2 asks clients to fetch a fresh upload URL and retry on 5xx / 408
        status, body = _call("POST", f"{api}{_B2_PATH}b2_get_upload_url", {"Authorization": token, "Content-Type": "application/json"},
                             json.dumps({"bucketId": bucket_id}).encode(), timeout=30)
        if status != 200:
            raise _b2_error("get_upload_url", status, body)
        up = json.loads(body)
        if not _b2_ok_url(up.get("uploadUrl", "")):
            raise BackupError("B2 returned an unexpected upload address")
        status, body = _call("POST", up["uploadUrl"], {
            "Authorization": up["authorizationToken"], "X-Bz-File-Name": urllib.parse.quote(prefix + name, safe="/"),
            "Content-Type": "application/octet-stream", "X-Bz-Content-Sha1": sha1, "Content-Length": str(len(data))}, data)
        if status == 200:
            j = json.loads(body)
            if str(j.get("contentSha1", "")).lower() != sha1 or int(j.get("contentLength", -1)) != len(data):
                raise BackupError("B2 stored a different size or checksum than was sent")
            return {"file_id": j.get("fileId"), "bytes": len(data), "sha1": sha1}
        last = _b2_error("upload", status, body)
        if status < 500 and status != 408:
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


def due(now: datetime | None = None) -> bool:
    """One run a day, in the quiet window 02:00-05:00 Toronto, and only if none succeeded in the last 20 hours."""
    from zoneinfo import ZoneInfo
    now = now or datetime.now(timezone.utc)
    if not 2 <= now.astimezone(ZoneInfo("America/Toronto")).hour < 5:
        return False
    since = (now - timedelta(hours=20)).isoformat()
    rows = hq._request("GET", f"/rest/v1/audit_log?action=eq.backup_ok&at=gte.{urllib.parse.quote(since)}&select=id&limit=1") or []
    return not rows


def last_ok() -> dict | None:
    """The most recent successful backup's audit detail (file, bytes, sha256, rows, ...), for /backup status."""
    try:
        rows = hq._request("GET", "/rest/v1/audit_log?action=eq.backup_ok&select=at,detail&order=at.desc&limit=1") or []
        return {"at": rows[0]["at"], **rows[0]["detail"]} if rows else None
    except Exception:
        return None


def run(force: bool = False) -> dict:
    """Make, verify and upload one backup. Never raises. Failure is logged and told to the owner once."""
    out = {"ok": False, "reason": None}
    try:
        if not configured():
            out["reason"] = "not configured"; return out
        if not force and not due():
            out["reason"] = "not due"; return out
        blob, manifest = dump()
        enc = encrypt(blob)
        problems = verify(enc, manifest)
        if problems:
            raise BackupError("self-check failed: " + "; ".join(problems[:3]))
        digest = hashlib.sha256(enc).hexdigest()
        name = f"hq-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.tar.gz.enc"
        put = put_files({name: enc, name + ".sha256": f"{digest}  {name}\n".encode()})
        detail = {"file": name, "bytes": len(enc), "sha256": digest, "rows": manifest["total_rows"], "tables": len(manifest["tables"]),
                  "complete": manifest["complete"], "format": FORMAT, "target": put["target"], "build": manifest["engine_build"][:12],
                  "b2_file_id": (put["files"].get(name) or {}).get("file_id")}
        _audit("backup_ok", detail)
        out.update(ok=True, file=name, rows=manifest["total_rows"], sha256=digest, complete=manifest["complete"])
        if not manifest["complete"]:
            hq._request("POST", "/rest/v1/owner_messages", {"from_agent": "jarvis", "kind": "info", "channel": "telegram",
                        "body": "Backup saved, but it holds data only: the schema snapshot function is not installed in the database yet. Ask for the backup_schema migration."},
                        prefer="return=minimal")
    except Exception as e:
        msg = str(e) if isinstance(e, BackupError) else type(e).__name__   # only our own messages are known to be secret-free
        out["reason"] = msg[:200]
        _audit("backup_failed", {"error": out["reason"]})
        try:
            hq._request("POST", "/rest/v1/owner_messages", {"from_agent": "jarvis", "kind": "info", "channel": "telegram",
                        "body": f"Daily backup failed: {out['reason']}. Data is safe in the database; I will retry tomorrow night."}, prefer="return=minimal")
        except Exception:
            pass
    return out
