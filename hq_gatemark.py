"""Sender-side HIGH-WATER MARK for the outreach gate: what makes a restored database close itself.

The problem: the gate row, the suppression lists and the epoch counter all live in ONE database. A provider restore (PITR, a Supabase backup restore, a pg_dump reload) puts back an
older, self-consistent copy: gate 'verified', an old checkpoint, an old list. Nothing inside that copy can tell it is old. So the sender (this process) keeps the highest suppression
epoch it has ever seen OUTSIDE the database, and before every send (and on every engine tick) tells the database what it saw: public.ffm_sender_attest(epoch, instance).
  * database epoch < our mark, or another instance/timeline  -> the database was rolled back or replaced: the database closes its own gate for good (restore marker + close) and we refuse.
  * no mark at all (first run, a wiped state file, a lost bucket)                                    -> UNANCHORED: we refuse. Only the owner can anchor (/gate anchor), and only while the
    gate is open and was verified AFTER the last restore marker. A restored or re-created sender therefore never trusts a database on its own.
  * a store is configured but cannot be read                                                          -> refuse (fail closed). Nothing configured -> refuse.
Where the mark lives (no new paid infra, no new secret): (1) an APPEND-ONLY object per advance in the existing Backblaze B2 backup bucket under <prefix>gate/ (same BACKUP_PUT_URL /
BACKUP_AUTH the backups use; the recommended key has listFiles + writeFiles and cannot delete or overwrite, and the mark is carried in the FILE NAME so no read permission is needed);
(2) optionally an append-only JSON-lines file (GATE_HWM_FILE, e.g. on a Railway volume). The effective mark is the highest (generation, epoch) found in ANY configured store, so
losing one store does not lower it. Railway's container disk is ephemeral: a file there is wiped on redeploy, which means "unanchored" (safe direction), not "trusted".
LIMITS (also in DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 8): a restore that ALSO resets every store the sender uses, followed by an owner anchor, is not detectable by this
module; the owner's anchor is then the only barrier and it is only offered when the gate was re-verified after the last restore marker. Suppressions recorded after our last observation
and lost together with a restore to a point after that observation are not detected by the epoch (the tick keeps that window to one engine tick, and observe() should be called after
every withdrawal the bot records). A malicious holder of the service key can write any state; this defends against restores and bugs, not against a hostile service role."""
import json, os, re, time, urllib.parse

import hq

NAME_RE = re.compile(r"hwm-(\d{6})-(\d{12})-(\d+_\d+|unavailable)\.json$")
_CACHE = {"at": 0.0, "rec": None}
CACHE_SECONDS = 300      # the engine tick may use a cached read this old; a SEND never does


class GateMarkError(Exception):
    pass


def _fp_to_name(fp: str | None) -> str:
    return "unavailable" if not fp or fp == "unavailable" else fp.replace(":", "_")


def _name_to_fp(s: str) -> str | None:
    return None if s == "unavailable" else s.replace("_", ":")


def _rec(gen: int, epoch: int, fp: str | None) -> dict:
    return {"gen": int(gen), "epoch": int(epoch), "fp": None if (not fp or fp == "unavailable") else str(fp)}


def _key(r: dict) -> tuple:
    return (r["gen"], r["epoch"])


# ------------------------------------------------------------------ stores

class FileStore:
    kind = "file"

    def __init__(self, path: str):
        self.path = path

    def read(self) -> list:
        if not os.path.exists(self.path):
            return []
        out = []
        with open(self.path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    j = json.loads(line)
                    out.append(_rec(j["gen"], j["epoch"], j.get("fp")))
                except Exception:
                    raise GateMarkError("the high-water mark file is corrupt")    # never guess: a damaged mark must not read as "no mark" and re-anchor itself
        return out

    def append(self, rec: dict) -> None:
        d = os.path.dirname(os.path.abspath(self.path))
        os.makedirs(d, exist_ok=True)
        with open(self.path, "a") as f:
            f.write(json.dumps(rec) + "\n"); f.flush(); os.fsync(f.fileno())


class B2Store:
    kind = "b2"

    def __init__(self, url: str, auth: str):
        import hq_backup
        self.b = hq_backup
        self.bucket, prefix = hq_backup.b2_parse(url)
        self.prefix = prefix + "gate/"
        self.auth = auth

    def _session(self):
        return self.b.b2_authorize(self.auth)

    def read(self) -> list:
        token, api = self._session()
        out, start = [], None
        for _ in range(50):
            body = {"bucketId": self.bucket, "prefix": self.prefix, "maxFileCount": 1000}
            if start:
                body["startFileName"] = start
            status, raw = self.b._call("POST", f"{api}{self.b._B2_PATH}b2_list_file_names", {"Authorization": token, "Content-Type": "application/json"}, json.dumps(body).encode(), timeout=30)
            if status != 200:
                raise GateMarkError(f"B2 list failed (HTTP {status})")
            j = json.loads(raw)
            for f in j.get("files", []):
                m = NAME_RE.search(urllib.parse.unquote(f.get("fileName", "")))
                if m:
                    out.append(_rec(int(m.group(1)), int(m.group(2)), _name_to_fp(m.group(3))))
            start = j.get("nextFileName")
            if not start:
                return out
        raise GateMarkError("B2 listing did not finish")

    def append(self, rec: dict) -> None:
        token, api = self._session()
        name = f"hwm-{rec['gen']:06d}-{rec['epoch']:012d}-{_fp_to_name(rec['fp'])}.json"
        self.b.b2_put(name, json.dumps(rec).encode(), self.bucket, self.prefix, token, api)


def stores() -> list:
    out = []
    path = os.environ.get("GATE_HWM_FILE", "").strip()
    if path:
        out.append(FileStore(path))
    url, auth = os.environ.get("BACKUP_PUT_URL", ""), os.environ.get("BACKUP_AUTH", "")
    if url.startswith("b2://") and auth:
        out.append(B2Store(url, auth))
    return out


def read_mark(force: bool = True) -> dict | None:
    """The highest (generation, epoch) in any configured store, or None when none holds one. Raises GateMarkError when nothing is configured or any store cannot be read."""
    if not force and _CACHE["rec"] is not None and time.time() - _CACHE["at"] < CACHE_SECONDS:
        return _CACHE["rec"]
    ss = stores()
    if not ss:
        raise GateMarkError("no high-water mark store is configured (set GATE_HWM_FILE, or BACKUP_PUT_URL=b2://... with BACKUP_AUTH)")
    best = None
    for s in ss:
        try:
            for r in s.read():
                if best is None or _key(r) > _key(best):
                    best = r
        except GateMarkError:
            raise
        except Exception as e:
            raise GateMarkError(f"the {s.kind} high-water mark store cannot be read ({type(e).__name__})")
    _CACHE.update(at=time.time(), rec=best)
    return best


def write_mark(rec: dict) -> None:
    """Append to EVERY configured store (a failure in any one is an error: the stores must not drift apart)."""
    ss = stores()
    if not ss:
        raise GateMarkError("no high-water mark store is configured")
    for s in ss:
        try:
            s.append(rec)
        except GateMarkError:
            raise
        except Exception as e:
            raise GateMarkError(f"the {s.kind} high-water mark store cannot be written ({type(e).__name__})")
    _CACHE.update(at=time.time(), rec=rec if (_CACHE["rec"] is None or _key(rec) > _key(_CACHE["rec"])) else _CACHE["rec"])


# ------------------------------------------------------------------ database

def _rpc(name: str, body: dict | None = None):
    got = hq._request("POST", f"/rest/v1/rpc/{name}", body or {}, timeout=15)
    if isinstance(got, list) and len(got) == 1:
        got = got[0]
    return got


def attest(force: bool = True) -> dict:
    """Compare the database with the external mark and tell the database. Never raises. {"ok": True, ...} or {"ok": False, "reason": ...}.
    On success the mark ADVANCES if the database epoch moved up (never down). A send path calls it with force=True (fresh read of every store)."""
    try:
        mark = read_mark(force)
    except GateMarkError as e:
        return {"ok": False, "reason": "hwm_unavailable", "detail": str(e)[:160]}
    except Exception as e:
        return {"ok": False, "reason": "hwm_unavailable", "detail": type(e).__name__}
    if mark is None:
        return {"ok": False, "reason": "sender_unanchored", "detail": "no high-water mark yet: the owner anchors this sender with /gate anchor once the gate has been verified"}
    try:
        got = _rpc("ffm_sender_attest", {"p_hwm_epoch": mark["epoch"], "p_hwm_instance": mark["fp"]})
    except Exception as e:
        return {"ok": False, "reason": "database_unreachable", "detail": type(e).__name__}
    if not isinstance(got, dict) or got.get("ok") is not True:
        return {"ok": False, "reason": (got or {}).get("reason", "unexpected_answer") if isinstance(got, dict) else "unexpected_answer", "detail": str((got or {}).get("detail", ""))[:200] if isinstance(got, dict) else ""}
    ep = got.get("epoch")
    if isinstance(ep, int) and ep > mark["epoch"]:
        try:
            write_mark(_rec(mark["gen"], ep, mark["fp"] or got.get("instance_fp")))
        except GateMarkError as e:
            return {"ok": False, "reason": "hwm_unavailable", "detail": str(e)[:160]}     # cannot record what we saw: do not send on it
    return {"ok": True, "epoch": ep, "open": bool(got.get("open"))}


def observe() -> dict:
    """Call right after the bot records a withdrawal / opt-out: advance the mark to the epoch that write produced, so a restore to a point just before it is detectable."""
    return attest(force=True)


def anchor(by: str = "owner") -> dict:
    """OWNER ACTION (called by /gate anchor). Starts a NEW generation at the database's current epoch. Allowed only while the gate is OPEN and was verified after the last restore
    marker, i.e. after the owner has re-established and verified the suppression list. This is the one operation that can LOWER the mark, and it is never done automatically."""
    try:
        st = _rpc("ffm_gate_state")
    except Exception as e:
        return {"ok": False, "reason": "database_unreachable", "detail": type(e).__name__}
    if not isinstance(st, dict) or not isinstance(st.get("epoch"), int):
        return {"ok": False, "reason": "no_epoch", "detail": "the database has no suppression epoch (migration not applied or schema restored without it)"}
    if st.get("open") is not True or not st.get("verified_at"):
        return {"ok": False, "reason": "gate_not_open", "detail": "verify the suppression list first (ops/OWNER_CONSENT_INTEGRITY.sql); the sender anchors only to a gate that is open"}
    lm, va = st.get("last_restore_marker"), st.get("verified_at")
    if lm and va and str(lm) >= str(va):
        return {"ok": False, "reason": "verified_before_restore", "detail": "the last verification is older than the last restore marker"}
    try:
        cur = read_mark(True)
        write_mark(_rec((cur["gen"] + 1) if cur else 1, st["epoch"], st.get("instance_fp")))
    except GateMarkError as e:
        return {"ok": False, "reason": "hwm_unavailable", "detail": str(e)[:160]}
    try:
        hq._request("POST", "/rest/v1/audit_log", {"actor": by, "action": "ffm_sender_anchored", "target": "gate/1", "detail": {"epoch": st["epoch"]}}, prefer="return=minimal")
    except Exception:
        pass
    return {"ok": True, "epoch": st["epoch"], "generation": (cur["gen"] + 1) if cur else 1}


def status_lines() -> list:
    out = []
    try:
        ss = stores()
        out.append("stores: " + (", ".join(s.kind for s in ss) or "NONE configured (outreach stays closed)"))
        m = read_mark(True)
        out.append("mark: " + (f"generation {m['gen']}, epoch {m['epoch']}" if m else "none (sender unanchored: outreach stays closed)"))
    except Exception as e:
        out.append(f"mark: unreadable ({str(e)[:120]}): outreach stays closed")
    try:
        st = _rpc("ffm_gate_state")
        out.append(f"database: epoch {st.get('epoch')}, gate {'OPEN' if st.get('open') else 'closed'} ({st.get('state')}), last restore marker {st.get('last_restore_marker')}")
    except Exception as e:
        out.append(f"database: unreachable or migration not applied ({type(e).__name__})")
    return out
