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
from hq_backup_keep import KEEP as KEEP_COLUMNS

logger = logging.getLogger(__name__)

FORMAT = 2
SKIP = {"push_config", "push_subscriptions"}   # hold private keys / endpoints: never exported
# Client personal data is NOT exported off-site (owner decision C, Nov 2026; DATA_CLASSIFICATION_AND_BACKUP_POLICY.md). The database decides what is exported
# (public.backup_export_policy(), migration 20261119_backup_exclude_client_pii_v1). This pattern is a SECOND, independent lock in this code: whatever the database says,
# a table that matches it is never written to a backup file. It is deliberately narrower than the database list; it exists so one wrong allow-list entry cannot leak.
ALWAYS_EXCLUDE = re.compile(r"^(ws_|ffm_)|^(client_workspaces|leads|outbox|lead_replies|deals|contact_suppressions|setters|setter_events|setter_payouts)$")
# Client text that the system copies into EXPORTED tables (DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 2). The database redacts these columns inside backup_snapshot()
# (migration 20261120_backup_redact_leak_paths_v1, mirrored by public.backup_redaction_spec()); this is the SECOND, independent lock in code:
#   * a snapshot that does not say it was redacted for all four required paths is refused (an old backup_snapshot() would export the raw text);
#   * the two-read fallback exports no string outside the spec's KEEP columns (blank_leak_columns, hq_backup_keep.KEEP generated from the spec);
#   * after redaction, any email address, phone number or contact-like JSON number still found in a strict column (the snapshot's own spec) makes the backup REFUSE to be written.
UNCERTAIN = "[redacted:uncertain]"
REDACTION_VERSION = 2
REQUIRED_REDACTION = {("audit_log", "detail"), ("ledger", "note"), ("tasks", "result"), ("agent_runs", "summary")}
# The two-read fallback has no database redactor, so it blanks EVERY string except (a) columns the export spec classifies KEEP (hq_backup_keep.KEEP, generated from
# backup_redaction_spec() by scripts/gen_backup_keep.py; a unit test fails when it is stale) and (b) values that are plainly not text (uuid, ISO timestamp / date, number).
# A column nobody classified yet is therefore blanked too: fail closed. json keeps keys, numbers and booleans.
STRICT_COLUMNS = {"audit_log": ["detail"], "ledger": ["note"], "tasks": ["result"], "agent_runs": ["summary"], "escalations": ["summary"]}   # floor only: the snapshot spec adds every other strict column
_EMAIL = re.compile(r"[A-Za-z0-9._%+'-]{2,}@[A-Za-z0-9-]{2,}(?:\.[A-Za-z0-9-]{2,})+")
_UUID_ISO = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[T ][0-9:.]+(?:Z|[+-][0-9:]+)?)?|[0-9a-fA-F]{32,}")   # ids, timestamps and hashes are not phone numbers
_PHONE = re.compile(r"(?<![0-9])\(?[0-9]{3}\)?[ .\-][0-9]{3}[ .\-][0-9]{4}(?![0-9])|(?<![0-9])[0-9]{10,}(?![0-9])")
# (the old built-in table list is gone on purpose: with no database export policy there is no off-site export, so a table can never be exported just because a list here names it)
ORDER = {"company_profile": "venture_slug", "departments": "slug", "agents": "slug", "app_owners": "email", "dayjob_days": "day",
         "tool_registry": "slug", "systems": "name", "action_policy": "action", "model_prices": "model", "setters": "id",
         "integration_status": "key", "alert_state": "key"}
PAGE = 1000
MAX_ROWS_PER_TABLE = 500_000
PAGE_REDACT = 200              # rows per backup_snapshot_page() call (each page scans and redacts its own rows)
SNAPSHOT_BUDGET_S = 40         # above this estimated cost one backup_snapshot() statement is too risky (statement_timeout) and the export is paged

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
    try:
        return Fernet(os.environ["BACKUP_KEY"].encode())
    except Exception:   # never echo the value: Fernet's own message can include parts of it
        raise BackupError("BACKUP_KEY is not a valid encryption key (must be a 44-character Fernet key ending in =)") from None


BACKUP_READER_ENV = "BACKUP_READER_JWT"      # a JWT with role = backup_reader (the narrow database identity that alone may run the backup functions); OWNER DECISION, see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md rule 12


def _rpc(path: str, body: dict | None = None, **kw):
    """Call a backup function as the backup identity. With BACKUP_READER_JWT set the call is made with that token (the service key is NOT sent); without it the service key is used, which
    works only on a database where the post-lockdown backup-identity migration has not been applied (after it, the database refuses the call and the backup fails closed, nothing is uploaded)."""
    tok = os.environ.get(BACKUP_READER_ENV, "").strip()
    if not tok:
        return hq._request("POST", path, body, **kw)
    reset = hq.AUTH_OVERRIDE.set(tok)
    try:
        return hq._request("POST", path, body, **kw)
    finally:
        hq.AUTH_OVERRIDE.reset(reset)


# ------------------------------------------------------------------ dump

def get_schema() -> dict | None:
    """The live schema description, or None when public.backup_schema() is not installed (old database)."""
    try:
        s = _rpc("/rest/v1/rpc/backup_schema", {}, timeout=60)
    except urllib.error.HTTPError as e:
        if e.code == 404:        # PostgREST: function not found (PGRST202) = migration not applied. Any other error must NOT silently downgrade the backup.
            return None
        raise
    if not isinstance(s, dict) or not s.get("tables"):
        raise BackupError("backup_schema() returned an unexpected result")
    return s


def _strings(o):
    if isinstance(o, str):
        yield o
    elif isinstance(o, dict):
        for k, v in o.items():
            yield from _strings(k); yield from _strings(v)
    elif isinstance(o, list):
        for v in o:
            yield from _strings(v)


# JSON numbers cannot be read as text, so the key decides (same rules as public.backup_redact_json_k): a number of 7+ digits under a key that is not an amount / count / size key is a phone, SIN or long id
_AMOUNT_KEY = re.compile(r"(^|_)(txid|xid|pid|seq|epoch|attempts|retries|amount|amt|cents|total|count|qty|quantity|sum|price|cost|fee|fees|balance|bytes|rows|chars|length|ms|secs|seconds|minutes|hours|days|limit|max|min|in|out|tokens|searches|spent|budget|cap|usd|cad|per_[a-z]+|to_cents|from_cents)($|_)")
_PII_KEY = re.compile(r"(^|[^a-z])(ph|phone|phones|tel|telephone|mobile|cell|cellphone|fax|ssn|sin|nas|dob|birthdate|birthday|birth|passport|licen[sc]e|card|iban|routing|transit|acct|account|accounts)([^a-z]|$)")


def _leaves(o, key=None):
    """(kind, value) for every string (also object keys) and every number in a JSON value; numbers carry the key they sit under."""
    if isinstance(o, str):
        yield "s", o
    elif isinstance(o, bool) or o is None:
        return
    elif isinstance(o, (int, float, Decimal)):
        yield "n", (key or "", o)
    elif isinstance(o, dict):
        for k, v in o.items():
            yield "s", str(k)
            yield from _leaves(v, str(k))
    elif isinstance(o, list):
        for v in o:
            yield from _leaves(v, key)


def _number_is_contact_like(key: str, n) -> bool:
    k = key.lower()
    if _PII_KEY.search(k):
        return True
    try:
        whole = str(abs(Decimal(str(n)))).split(".")[0]
    except Exception:
        return True
    return len(re.sub(r"[^0-9]", "", whole)) >= 7 and not _AMOUNT_KEY.search(k)


def _blank(o):
    if isinstance(o, str):
        return UNCERTAIN
    if isinstance(o, dict):
        return {k: _blank(v) for k, v in o.items()}
    if isinstance(o, list):
        return [_blank(v) for v in o]
    return o


_NOT_TEXT = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"                                              # uuid
                       r"|[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[T ][0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\.[0-9]{1,6})?)?(?:Z|[+-][0-9]{2}(?::?[0-9]{2})?)?)?"       # ISO date / date-time (a colon-separated time only)
                       r"|-?[0-9]{1,6}(?:\.[0-9]{1,4})?")                                                                                                 # a short number (never 7+ digits: that can be a phone)
_DIGIT_RUN = re.compile(r"[0-9][0-9 .()/+-]{5,}[0-9]|[0-9]{7,}")


def _blank_value(o, inside=False):
    """Fallback blanking. Strings become the marker unless they cannot carry text. Inside a JSON value EVERYTHING that can carry a name or a contact is replaced and the
    structure is kept: object keys become positional markers, a number of 7+ digits becomes 0, small numbers and booleans keep their value (a key such as "jpicardeau" or a number such as a phone is as much a leak as a string)."""
    if isinstance(o, str):
        return o if _NOT_TEXT.fullmatch(o) else UNCERTAIN
    if isinstance(o, dict):
        return {f"[redacted:key{n}]": _blank_value(v, True) for n, (k, v) in enumerate(o.items())}
    if isinstance(o, list):
        return [_blank_value(v, True) for v in o]
    if inside and not isinstance(o, bool) and isinstance(o, (int, float)) and _number_is_contact_like("", o):
        return 0                                  # 7+ digits (a phone number as a JSON number); counts, cents and flags keep their value
    return o


def _string_leaves(o):
    if isinstance(o, str):
        yield o
    elif isinstance(o, dict):
        for k, v in o.items():
            yield str(k)
            yield from _string_leaves(v)
    elif isinstance(o, list):
        for v in o:
            yield from _string_leaves(v)


def assert_no_digit_runs(table: str, rows: list) -> None:
    """Fallback output only: in every column the fallback blanked (not KEEP, light ones included) no string or key may still hold a run of 7+ digits (a phone number written any way)."""
    for r in rows:
        for c, v in r.items():
            if (table, c) in KEEP_COLUMNS or v is None:
                continue
            for sv in _string_leaves(v):
                if sv != UNCERTAIN and _DIGIT_RUN.search(_UUID_ISO.sub(" ", sv)):
                    raise BackupError(f"digits that can be a phone number survive in {table}.{c}; refusing to write the backup")


def blank_leak_columns(table: str, rows: list) -> list:
    """Two-read fallback only (the database did not redact): every string of every column that is not KEEP in the export spec is replaced by the marker."""
    out = []
    for r in rows:
        out.append({c: (v if (table, c) in KEEP_COLUMNS or v is None else _blank_value(v)) for c, v in r.items()})
    return out


def check_redaction(snap: dict) -> dict:
    """A snapshot is only trusted if the database says it redacted every required leak path (an old backup_snapshot() would carry the raw client text)."""
    red = snap.get("redaction")
    if not (isinstance(red, dict) and isinstance(red.get("version"), int) and red["version"] >= REDACTION_VERSION and isinstance(red.get("spec"), list)):
        raise BackupError("backup_snapshot() did not redact the client-text leak paths (migration 20261120_backup_redact_leak_paths_v1 missing); refusing to export")
    have = {(str(s.get("table_name")), str(s.get("column_name"))) for s in red["spec"] if isinstance(s, dict)}
    missing = sorted(REQUIRED_REDACTION - have)
    if missing:
        raise BackupError("the redaction spec does not cover " + ", ".join(f"{t}.{c}" for t, c in missing) + "; refusing to export")
    return red


def blanked_columns(spec) -> list:
    """TABLE.COLUMN of every column the database exports blank (mode 'blank': free text written by agents, scrapers, clients or counterparties). They go into the manifest so the restore tool
    knows they hold no data: it restores them as NULL where the column allows it and as an empty value (empty string / {} / []) where it does not."""
    return sorted(f"{x.get('table_name')}.{x.get('column_name')}" for x in spec or [] if isinstance(x, dict) and x.get("mode") == "blank")


def strict_columns(spec) -> dict:
    """{table: [column]} of every strict column in the snapshot's own spec (so a new column the database treats as strict is checked here too)."""
    out = {}
    for sp in spec or []:
        if isinstance(sp, dict) and sp.get("mode") == "strict":
            out.setdefault(str(sp.get("table_name")), []).append(str(sp.get("column_name")))
    for t, cols in STRICT_COLUMNS.items():
        for c in cols:
            if c not in out.setdefault(t, []):
                out[t].append(c)
    return out


def assert_redacted(data: dict, spec=None) -> dict:
    """Second lock (a backstop: the database redactor applies the same tests last and blanks what it would refuse). After redaction no email address, phone number or contact-like JSON number may remain in a strict column.
    Returns {table.column: number of fields that fail closed}. On a hit it names TABLE.COLUMN and the number of fields, NEVER a value, and still refuses the whole backup (fail closed)."""
    uncertain, bad = {}, {}
    for t, cols in strict_columns(spec).items():
        for row in data.get(t) or []:
            for c in cols:
                v = row.get(c)
                for kind, sv in _leaves(v):
                    if kind == "n":
                        if _number_is_contact_like(*sv):
                            bad[f"{t}.{c}"] = bad.get(f"{t}.{c}", 0) + 1
                    elif sv == UNCERTAIN:
                        uncertain[f"{t}.{c}"] = uncertain.get(f"{t}.{c}", 0) + 1
                    elif _EMAIL.search(sv) or _PHONE.search(_UUID_ISO.sub(" ", sv)):
                        bad[f"{t}.{c}"] = bad.get(f"{t}.{c}", 0) + 1
    if bad:
        raise BackupError("contact data is still present after redaction in " + ", ".join(f"{k} ({n} field(s))" for k, n in sorted(bad.items())) + "; refusing to write the backup (the database redactor should have blanked it: report this)")
    return uncertain


def _check_policy(p) -> dict:
    if not (isinstance(p, dict) and isinstance(p.get("exported"), list) and isinstance(p.get("excluded"), list) and isinstance(p.get("unclassified"), list)):
        raise BackupError("backup_export_policy() returned an unexpected result; refusing to export")
    bad = sorted(t for t in p["exported"] if ALWAYS_EXCLUDE.search(str(t)))
    if bad:
        raise BackupError("export policy lists client tables as exportable (" + ", ".join(bad[:5]) + "); refusing to export")
    return p


def get_policy() -> dict:
    """Which tables may leave the database. FAIL CLOSED: without the policy function there is no off-site export at all (never 'export everything')."""
    try:
        p = _rpc("/rest/v1/rpc/backup_export_policy", {}, timeout=60)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise BackupError("backup_export_policy() is not installed (migration 20261119_backup_exclude_client_pii_v1); refusing to export client data off-site") from None
        raise
    return _check_policy(p)


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
        rows = blank_leak_columns(t, _read_table(t, schema))
        assert_no_digit_runs(t, rows)
        assert_redacted({t: rows})          # the same second lock as for the database-redacted path: a contact-like leaf in a strict column refuses the backup
        out[t] = (("\n".join(row_json(r) for r in rows)).encode(), len(rows))
    return out


def _epoch() -> dict | None:
    """The redaction-source epoch vector (backup_epoch(): one counter bumped by owner-only triggers on every insert, update, delete and truncate of a client / lead / suppression source table and of the deny-list,
    plus the source row counts and a hash of the redaction code and the export policy). None when the database cannot tell: that is NOT consistent."""
    try:
        e = _rpc("/rest/v1/rpc/backup_epoch", {}, timeout=60)
    except Exception:
        return None
    return e if isinstance(e, dict) and isinstance(e.get("seq"), int) and not isinstance(e.get("seq"), bool) else None


def _read_consistent(names, schema) -> tuple[dict, dict]:
    """Fallback (no database snapshot function): the REST API cannot give one transaction across requests, so every table is read twice and the pass counts only when both reads are
    byte-identical AND the redaction-source epoch is the same before and after (nothing changed anywhere). Without a readable epoch the result is NOT verified consistent, and a backup
    that is not verified consistent is never uploaded (run())."""
    last = None
    for attempt in range(1, CONSISTENCY_ATTEMPTS + 1):
        e0 = _epoch()
        first = _read_all(names, schema)
        second = _read_all(names, schema)
        e1 = _epoch()
        moved = sorted(t for t in names if hashlib.sha256(first[t][0]).digest() != hashlib.sha256(second[t][0]).digest())
        epoch_state = "unavailable" if (e0 is None or e1 is None) else ("unchanged" if e0 == e1 else "changed")
        last = (second, moved, epoch_state, attempt)
        if not moved and epoch_state == "unchanged":
            return second, {"consistent": True, "method": "two identical full reads and an unchanged source epoch", "epoch": epoch_state, "attempts": attempt}
        if epoch_state == "unavailable":
            break                                                     # retrying cannot make an unreadable epoch readable
    second, moved, epoch_state, attempt = last
    return second, {"consistent": False, "method": "two identical full reads and an unchanged source epoch", "epoch": epoch_state, "attempts": attempt, "changing_tables": moved[:10]}


def _encode_rows(rows: list) -> tuple[bytes, int]:
    lines = sorted(row_json(r) for r in rows)          # deterministic order: the same data always gives the same file hash
    return "\n".join(lines).encode(), len(rows)


def _snapshot_cost() -> dict | None:
    try:
        c = _rpc("/rest/v1/rpc/backup_snapshot_cost", {}, timeout=60)
        return c if isinstance(c, dict) and isinstance(c.get("est_seconds"), (int, float)) else None
    except Exception:
        return None


def _deny_prepare():
    """The whole-export deny-list scan, once, for this run. Returns this run's id (random, bound to the caller) or None (then every page runs the whole scan itself: slower, never skipped)."""
    try:
        prep = _rpc("/rest/v1/rpc/backup_deny_prepare", {}, timeout=300)
        run = prep.get("run") if isinstance(prep, dict) else None
        return run if isinstance(run, str) and len(run) == 36 else None
    except Exception:
        return None


def _deny_release(run) -> None:
    """Delete THIS run's cached scan result (and expired ones). Best effort: the database also expires and purges them."""
    try:
        _rpc("/rest/v1/rpc/backup_deny_release", {"p_run": run} if run else {}, timeout=60)
    except Exception:
        pass


def _read_paged(pol: dict, schema: dict) -> tuple[dict, dict, dict]:
    """Redacted export in pages for volumes one statement cannot cover. Every table's RAW digest (a hash, no data) is read before and after the pages;
    equal digests prove nothing changed while we read (the same claim as two identical full reads, with no raw text leaving the database). Retries, then flags consistent=False."""
    names = [t for t in pol["exported"] if t not in SKIP]
    meta = _rpc("/rest/v1/rpc/backup_redaction_meta", {}, timeout=60)
    check_redaction({"redaction": meta})
    last = None
    for attempt in range(1, CONSISTENCY_ATTEMPTS + 1):
        e0 = _epoch()
        before = {t: _rpc("/rest/v1/rpc/backup_table_digest", {"p_table": t}, timeout=120) for t in names}
        run = _deny_prepare()
        try:
            data = {}
            for t in names:
                rows, off = [], 0
                while off < MAX_ROWS_PER_TABLE:
                    page = _rpc("/rest/v1/rpc/backup_snapshot_page", {"p_table": t, "p_offset": off, "p_limit": PAGE_REDACT, **({"p_run": run} if run else {})}, timeout=180)
                    got = page.get("rows") if isinstance(page, dict) else None
                    if not isinstance(got, list):
                        raise BackupError(f"{t}: backup_snapshot_page() returned an unexpected result")
                    if not got:
                        break
                    rows.extend(got)
                    off += len(got)
                else:
                    raise BackupError(f"{t}: more than {MAX_ROWS_PER_TABLE} rows; refusing to write a partial backup")
                data[t] = rows
        finally:
            _deny_release(run)                         # on success AND on any exception: this run's cached scan result is deleted (an unreleased one also expires by itself)
        after = {t: _rpc("/rest/v1/rpc/backup_table_digest", {"p_table": t}, timeout=120) for t in names}
        e1 = _epoch()
        epoch_state = "unavailable" if (e0 is None or e1 is None) else ("unchanged" if e0 == e1 else "changed")
        moved = sorted(t for t in names if before[t] != after[t])
        last = (data, meta, moved, epoch_state)
        if not moved and epoch_state == "unchanged":
            return data, meta, {"consistent": True, "method": "paged redacted read between two identical raw table digests and an unchanged redaction-source epoch", "epoch": epoch_state, "attempts": attempt}
        if epoch_state == "unavailable":
            break
    return last[0], last[1], {"consistent": False, "method": "paged redacted read between two raw table digests and the redaction-source epoch", "epoch": last[3], "attempts": CONSISTENCY_ATTEMPTS, "changing_tables": last[2][:10]}


def _try_snapshot() -> tuple[dict | None, str]:
    """One database call that returns every table AND the schema from a single SQL statement, so they are mutually consistent.
    Returns (snapshot, "") or (None, reason). Any problem falls back to the two-read method rather than failing the backup."""
    try:
        snap = _rpc("/rest/v1/rpc/backup_snapshot", {}, timeout=180, exact=True)
    except urllib.error.HTTPError as e:
        return None, ("backup_snapshot() not installed" if e.code == 404 else f"backup_snapshot() failed (HTTP {e.code})")
    except Exception as e:
        return None, f"backup_snapshot() failed ({type(e).__name__})"
    if not isinstance(snap, dict) or not isinstance(snap.get("data"), dict) or not isinstance(snap.get("schema"), dict) or not snap["schema"].get("tables"):
        return None, "backup_snapshot() returned an unexpected result"
    check_redaction(snap)                              # raises BackupError: a snapshot that was not redacted is never written, and is not "fallen back" from either
    pol = _check_policy(snap.get("policy"))            # a snapshot without a policy is from the old function, which exports client data: refuse (raises BackupError)
    want = sorted(t for t in pol["exported"] if t not in SKIP)
    if sorted(snap["data"]) != want or SKIP & set(snap["data"]) or any(ALWAYS_EXCLUDE.search(t) for t in snap["data"]):
        return None, "backup_snapshot() table list does not match its own policy"
    return snap, ""


def dump() -> tuple[bytes, dict]:
    """Returns (plain tar.gz bytes, manifest). Raises if any table cannot be read completely."""
    manifest = {"format": FORMAT, "created_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "engine_build": (os.environ.get("RAILWAY_GIT_COMMIT_SHA") or os.environ.get("GIT_COMMIT") or "unknown")[:40],
                "skipped": sorted(SKIP), "tables": {}, "schema": None}
    cost = _snapshot_cost()
    paged = bool(cost and cost["est_seconds"] > SNAPSHOT_BUDGET_S)
    if paged:
        schema = get_schema()
        pol = get_policy()
        if not schema:
            raise BackupError("paged export needs the schema; refusing to write a partial backup")
        pdata, meta, cons = _read_paged(pol, schema)
        unc = assert_redacted(pdata, meta.get("spec"))
        manifest["redaction"] = {"mode": "database_paged", "version": meta["version"], "estimated_single_statement_seconds": cost["est_seconds"],
                                 "columns": sorted(f"{s['table_name']}.{s['column_name']}" for s in meta["spec"] if isinstance(s, dict)), "blanked_columns": blanked_columns(meta["spec"]), "fields_failed_closed": unc}
        data_by_table = {t: _encode_rows(rows) for t, rows in sorted(pdata.items())}
        manifest["table_list_source"] = "database export policy"
        manifest["consistency"] = cons
        names = list(data_by_table)
        after = get_schema()
        if not after or sorted(t["name"] for t in after["tables"]) != sorted(t["name"] for t in schema["tables"]) or get_policy()["exported"] != pol["exported"]:
            raise BackupError("tables were added or removed while the backup was being read; will retry later")
        schema = after
        snap, why = None, ""
    else:
        snap, why = _try_snapshot()
    if paged:
        pass
    elif snap:
        pol = snap["policy"]
        schema = snap["schema"]
        unc = assert_redacted(snap["data"], snap["redaction"]["spec"])
        manifest["redaction"] = {"mode": "database", "version": snap["redaction"]["version"], "known_client_terms": snap["redaction"].get("known_client_terms"),
                                 "columns": sorted(f"{s['table_name']}.{s['column_name']}" for s in snap["redaction"]["spec"] if isinstance(s, dict)), "blanked_columns": blanked_columns(snap["redaction"]["spec"]), "fields_failed_closed": unc}
        data_by_table = {t: _encode_rows(rows) for t, rows in sorted(snap["data"].items())}
        manifest["table_list_source"] = "database export policy"
        manifest["consistency"] = {"consistent": True, "method": "single SQL statement snapshot (all tables + schema)", "attempts": 1}
        names = list(data_by_table)
    else:
        schema = get_schema()
        pol = get_policy()
        names = [t for t in pol["exported"] if t not in SKIP]
        manifest["table_list_source"] = "database export policy"
        data_by_table, manifest["consistency"] = _read_consistent(names, schema)
        manifest["consistency"]["snapshot_unavailable"] = why
        manifest["redaction"] = {"mode": "fallback_blanked", "rule": "every string outside the spec's KEEP columns is blanked", "keep_columns": len(KEEP_COLUMNS)}
        if schema:
            # Read the schema AGAIN after the data: sequence positions must not be older than the rows we saved (a restored sequence behind the
            # data would hand out ids that already exist). If the table list changed while we were reading, refuse: tomorrow's run starts clean.
            after = get_schema()
            if not after or sorted(t["name"] for t in after["tables"]) != sorted(t["name"] for t in schema["tables"]) or get_policy()["exported"] != pol["exported"]:
                raise BackupError("tables were added or removed while the backup was being read; will retry later")
            schema = after
    if any(ALWAYS_EXCLUDE.search(t) for t in names):
        raise BackupError("a client table reached the export list; refusing to write the backup")
    manifest["excluded"] = sorted((str(e.get("table")), str(e.get("class"))) for e in pol["excluded"] if isinstance(e, dict))    # names and classes only, never data
    manifest["excluded"] = [list(x) for x in manifest["excluded"]]
    manifest["unclassified_excluded"] = sorted(str(t) for t in pol["unclassified"])
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


def _require_verified_consistency(manifest: dict) -> None:
    """A backup is uploaded ONLY when its consistency was explicitly verified: consistency.consistent is exactly True. False, missing, None, a string or anything else is refused, whatever
    the export mode (single statement, paged, fallback). The previous verified backup is never touched (the bot's key cannot delete; nothing here overwrites a name)."""
    c = manifest.get("consistency") if isinstance(manifest, dict) else None
    if not (isinstance(c, dict) and c.get("consistent") is True):
        why = "missing" if not isinstance(c, dict) else ("the data changed while it was read" if c.get("consistent") is False else "unknown")
        ep = c.get("epoch") if isinstance(c, dict) else None
        raise BackupError(f"backup not verified consistent ({why}{', source epoch ' + str(ep) if ep else ''}); not uploaded, the previous verified backup is kept; will retry later")


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
            if not (isinstance(manifest.get("consistency"), dict) and manifest["consistency"].get("consistent") is True):
                problems.append("consistency is not verified true")
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


PUT_ATTEMPTS = 3


def _put_one(target: str, name: str, data: bytes, headers: dict, others_stored: bool) -> dict:
    """PUT one file. Network errors, 408, 429 and 5xx are retried with backoff (a transient outage must not cost a night's backup);
    401/403/413 and other 4xx are final and say what to check. Messages never contain the URL, the key or the auth value."""
    suffix = " (the backup file itself was stored, but its checksum file was not)" if others_stored else ""
    for attempt in range(PUT_ATTEMPTS):
        try:
            status, _ = _call("PUT", target, headers, data)
        except (urllib.error.URLError, OSError):
            status = None
        if status is not None and 200 <= status < 300:
            return {"bytes": len(data)}
        retryable = status is None or status in (408, 429) or status >= 500
        if retryable and attempt + 1 < PUT_ATTEMPTS:
            time.sleep(min(2 ** attempt, 8) if not _NO_SLEEP else 0)
            continue
        if status is None:
            raise BackupError(f"backup target unreachable after {PUT_ATTEMPTS} tries (network error){suffix}")
        hint = {401: ": check BACKUP_AUTH", 403: ": check BACKUP_AUTH", 413: ": the target refused the file size", 404: ": check BACKUP_PUT_URL"}.get(status, "")
        raise BackupError(f"upload of {name} failed (HTTP {status}{hint}){suffix}")
    raise BackupError(f"upload of {name} failed")   # unreachable; keeps the type checker honest


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
        out[n] = _put_one(url.replace("{name}", urllib.parse.quote(n, safe="")), n, d, headers, bool(out))
    return {"target": "put", "files": out}


def upload(name: str, encrypted: bytes, manifest: dict | None = None) -> bool:
    """Single-file upload kept for callers/tests that only need success or failure. Defence in depth: like run(), it refuses anything whose manifest does not say consistent is exactly True
    (no manifest = refused), so no code path can put an unverified archive off-site."""
    try:
        _require_verified_consistency(manifest or {})
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
        hq._request("POST", "/rest/v1/owner_messages", {"from_agent": "jarvis", "kind": "health", "channel": "telegram", "body": body}, prefer="return=minimal")
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
            _require_verified_consistency(manifest)
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
        if not manifest["complete"]:
            _tell_owner("Backup saved, but it holds data only: the schema snapshot function is not installed in the database yet. Ask for the backup_schema migration.")
    finally:
        _RUN_LOCK.release()
    return out
