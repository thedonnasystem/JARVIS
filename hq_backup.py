"""Encrypted daily backup of the HQ database. DORMANT until BACKUP_KEY (a Fernet key) and BACKUP_PUT_URL are set in Railway.
BACKUP_PUT_URL is any HTTPS endpoint that accepts an HTTP PUT of the file; '{name}' in it is replaced by the file name
(works with WebDAV/Nextcloud, B2/S3 presigned-style gateways, a second Supabase Storage bucket). BACKUP_AUTH, if set, is sent as the
Authorization header. Put the backup somewhere that is NOT this Supabase project, or one outage takes both.
The file is gzip(JSONL per table) encrypted with Fernet; push_config (private keys) is never exported.
Restore check: verify() decrypts and counts rows per table so a backup that cannot be read is caught the day it is made."""
import gzip, io, json, os, tarfile, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone

import hq

SKIP = {"push_config", "push_subscriptions"}
TABLES = ["departments", "deals", "audit_log", "build_requests", "company_profile", "dayjob_days", "dayjob_targets", "agents",
          "accounts_registry", "handbook", "ledger", "ideas", "escalations", "leads", "human_handoffs", "owner_messages", "model_prices",
          "predictions", "tool_registry", "reconciliation_flags", "tasks", "systems", "llm_calls", "ventures", "memory", "outbox",
          "system_state", "missions", "agent_runs", "action_policy", "action_log", "approval_requests", "capital_policy",
          "spend_reservations", "bank_accounts", "bank_balances", "bank_transactions", "mission_outcomes", "org_changes", "venture_goals",
          "app_owners", "web_messages", "payment_instructions", "venture_assets", "venture_procedures", "account_requests",
          "setter_terms", "setters", "setter_events", "setter_payouts", "waterfall_policy"]
ORDER = {"company_profile": "venture_slug", "departments": "slug", "agents": "slug", "app_owners": "email", "dayjob_days": "day",
         "tool_registry": "slug", "systems": "name", "action_policy": "action", "model_prices": "model", "setters": "id"}
PAGE = 1000
MAX_ROWS_PER_TABLE = 500_000


def configured() -> bool:
    return bool(os.environ.get("BACKUP_KEY") and os.environ.get("BACKUP_PUT_URL"))


def _fernet():
    from cryptography.fernet import Fernet
    return Fernet(os.environ["BACKUP_KEY"].encode())


def dump() -> tuple[bytes, dict]:
    """Returns (plain tar.gz bytes, {table: rowcount}). Raises if any table cannot be read completely."""
    counts, buf = {}, io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for t in TABLES:
            if t in SKIP:
                continue
            rows, off = [], 0
            order = f"&order={ORDER.get(t, 'id')}.asc"
            while off < MAX_ROWS_PER_TABLE:
                try:
                    page = hq._request("GET", f"/rest/v1/{t}?select=*{order}&limit={PAGE}&offset={off}") or []
                except urllib.error.HTTPError as e:
                    if e.code != 400 or not order:   # no such sort column: fall back to unordered paging (small tables)
                        raise
                    order = ""
                    page = hq._request("GET", f"/rest/v1/{t}?select=*&limit={PAGE}&offset={off}") or []
                rows.extend(page)
                if len(page) < PAGE:
                    break
                off += PAGE
            data = ("\n".join(json.dumps(r, default=str, separators=(",", ":")) for r in rows)).encode()
            info = tarfile.TarInfo(name=f"{t}.jsonl"); info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
            counts[t] = len(rows)
    return buf.getvalue(), counts


def encrypt(blob: bytes) -> bytes:
    return _fernet().encrypt(blob)


def verify(encrypted: bytes, expected: dict) -> list[str]:
    """Decrypt and recount. Returns a list of problems (empty = restorable)."""
    problems = []
    try:
        plain = _fernet().decrypt(encrypted)
        with tarfile.open(fileobj=io.BytesIO(plain), mode="r:gz") as tar:
            for t, n in expected.items():
                f = tar.extractfile(f"{t}.jsonl")
                got = 0 if f is None else len([ln for ln in f.read().decode().split("\n") if ln.strip()])
                if got != n:
                    problems.append(f"{t}: expected {n} rows, found {got}")
    except Exception as e:
        problems.append(f"cannot read backup: {type(e).__name__}")
    return problems


def upload(name: str, encrypted: bytes) -> bool:
    url = os.environ["BACKUP_PUT_URL"].replace("{name}", urllib.parse.quote(name, safe=""))
    if not url.startswith("https://"):
        return False
    headers = {"Content-Type": "application/octet-stream"}
    if os.environ.get("BACKUP_AUTH"):
        headers["Authorization"] = os.environ["BACKUP_AUTH"]
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=encrypted, method="PUT", headers=headers), timeout=120) as r:
            return 200 <= r.status < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False


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


def run(force: bool = False) -> dict:
    """Make, verify and upload one backup. Never raises. Failure is logged and told to the owner once."""
    out = {"ok": False, "reason": None}
    try:
        if not configured():
            out["reason"] = "not configured"; return out
        if not force and not due():
            out["reason"] = "not due"; return out
        blob, counts = dump()
        enc = encrypt(blob)
        problems = verify(enc, counts)
        if problems:
            raise RuntimeError("; ".join(problems[:3]))
        name = f"hq-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.tar.gz.enc"
        if not upload(name, enc):
            raise RuntimeError("upload failed")
        _audit("backup_ok", {"file": name, "bytes": len(enc), "rows": sum(counts.values()), "tables": len(counts)})
        out.update(ok=True, file=name, rows=sum(counts.values()))
    except Exception as e:
        out["reason"] = f"{type(e).__name__}: {e}"[:200]
        _audit("backup_failed", {"error": out["reason"]})
        try:
            hq._request("POST", "/rest/v1/owner_messages", {"from_agent": "jarvis", "kind": "info", "channel": "telegram",
                        "body": f"Daily backup failed: {out['reason']}. Data is safe in the database; I will retry tomorrow night."}, prefer="return=minimal")
        except Exception:
            pass
    return out
