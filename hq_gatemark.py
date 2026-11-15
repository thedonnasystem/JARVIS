"""Sender-side HIGH-WATER MARK for the outreach gate: what makes a restored database close itself.

The problem: the gate row, the suppression lists and the epoch counter all live in ONE database. A provider restore (PITR, a Supabase backup restore, a pg_dump reload) puts back an
older, self-consistent copy: gate 'verified', an old checkpoint, an old list. Nothing inside that copy can tell it is old. So the sender (this process) keeps the highest suppression
epoch it has ever seen OUTSIDE the database, and before every send (and on every engine tick) tells the database what it saw: public.ffm_sender_attest(generation, epoch, instance).
  * database epoch < our mark, or another instance/timeline  -> the database was rolled back or replaced: the database closes its own gate for good (restore marker + close) and we refuse.
  * no mark at all (first run, a wiped state file, a lost bucket)                                    -> UNANCHORED: we refuse. Only the owner can anchor (/gate anchor), and only while the
    gate is freshly verified AFTER the newest restore marker. A restored or re-created sender therefore never trusts a database on its own.
  * THE ANCHOR NEVER LOWERS THE MARK BY ITSELF: if the database epoch is below our mark, /gate anchor is refused unless the OWNER recorded a restore (ffm_owner_record_restore) that this
    mark has not consumed, and the verification came after it (ffm_gate_core_ok). The database enforces the same rule against its own stored mark (ffm_sender_mark).
  * a store is configured but cannot be read                                                          -> refuse (fail closed). Nothing configured -> refuse.
Where the mark lives (no new paid infra, no new secret): (1) an object per advance in the existing Backblaze B2 backup bucket under <prefix>gate/ (same BACKUP_PUT_URL / BACKUP_AUTH the
backups use; the mark is carried in the FILE NAME so no file-read permission is needed). TRUE B2 CAPABILITY (Backblaze docs, 'Application Key Capabilities'): writeFiles covers BOTH
b2_upload_file AND b2_hide_file; deleteFiles (b2_delete_file_version) is separate. So a key limited to listFiles + writeFiles CAN hide a mark object (it then vanishes from
b2_list_file_names) and CAN upload a new version under the same name, but it CANNOT delete any version. We therefore read with b2_list_file_versions, which still shows hidden uploads, take the
maximum over every upload version, and COUNT hide markers (shown by /gate status, never silently ignored). Never give this key deleteFiles, and keep any bucket lifecycle rule off gate/;
(2) optionally an append-only JSON-lines file (GATE_HWM_FILE, e.g. on a Railway volume). The effective mark is the highest (generation, epoch) found in ANY configured store, so
losing one store does not lower it. Railway's container disk is ephemeral: a file there is wiped on redeploy, which means "unanchored" (safe direction), not "trusted".
LIMITS (also in DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 8): a restore that ALSO resets every store the sender uses, followed by an owner anchor, is not detectable by this
module; the owner's anchor is then the only barrier and it is only offered when the gate was re-verified after the last restore marker. Suppressions recorded after our last observation
and lost together with a restore to a point after that observation are not detected by the epoch (the tick keeps that window to one engine tick, and observe() should be called after
every withdrawal the bot records). A malicious holder of the service key can write any state; this defends against restores and bugs, not against a hostile service role."""
import json, os, re, time, urllib.parse

import hq

NAME_RE = re.compile(r"hwm-(\d{6})-(\d{12})-(\d{9})-(\d{1,20}(?:_\d{1,10}){1,3}|unavailable)\.json")     # matched with fullmatch against <prefix>gate/<this>; nothing else under the prefix counts
_CACHE = {"at": 0.0, "rec": None}
CACHE_SECONDS = 300      # the engine tick may use a cached read this old; a SEND never does


class GateMarkError(Exception):
    pass


def _fp_to_name(fp: str | None) -> str:
    return "unavailable" if not fp or fp == "unavailable" else fp.replace(":", "_")


def _name_to_fp(s: str) -> str | None:
    return None if s == "unavailable" else s.replace("_", ":")


def _rec(gen: int, epoch: int, fp: str | None, om: int = 0) -> dict:
    """gen: anchor generation; epoch: highest suppression epoch seen; fp: instance fingerprint; om: the newest owner restore-marker id this generation consumed."""
    return {"gen": int(gen), "epoch": int(epoch), "fp": None if (not fp or fp == "unavailable") else str(fp), "om": int(om)}


def _key(r: dict) -> tuple:
    return (r["gen"], r["epoch"], r.get("om", 0))


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
                    out.append(_rec(j["gen"], j["epoch"], j.get("fp"), j.get("om", 0)))
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
        self.hides = 0          # hide markers seen under the prefix on the last read (tampering, a mistake, or a lifecycle rule: always shown)
        self.foreign = 0        # objects under the prefix that are not mark files (ignored, but shown)

    def _session(self):
        return self.b.b2_authorize(self.auth)

    def _name_re(self):
        return re.compile(re.escape(self.prefix) + NAME_RE.pattern)

    def read(self) -> list:
        """b2_list_file_versions, NOT b2_list_file_names: a hidden object is gone from the latter but its upload version is still listed here, so hiding cannot lower the mark."""
        token, api = self._session()
        rx = self._name_re()
        out, hides, foreign = [], 0, 0
        start_name = start_id = None
        for _ in range(100):
            body = {"bucketId": self.bucket, "prefix": self.prefix, "maxFileCount": 1000}
            if start_name:
                body["startFileName"] = start_name
                if start_id:
                    body["startFileId"] = start_id
            status, raw = self.b._call("POST", f"{api}{self.b._B2_PATH}b2_list_file_versions", {"Authorization": token, "Content-Type": "application/json"}, json.dumps(body).encode(), timeout=30)
            if status != 200:
                raise GateMarkError(f"B2 list failed (HTTP {status})")
            j = json.loads(raw)
            for f in j.get("files", []):
                action, name = f.get("action"), f.get("fileName", "")
                if action == "hide":
                    hides += 1
                    continue
                if action != "upload":
                    continue
                m = rx.fullmatch(name)
                if not m:
                    foreign += 1
                    continue
                out.append(_rec(int(m.group(1)), int(m.group(2)), _name_to_fp(m.group(4)), int(m.group(3))))
            start_name, start_id = j.get("nextFileName"), j.get("nextFileId")
            if not start_name:
                self.hides, self.foreign = hides, foreign
                return out
        raise GateMarkError("B2 listing did not finish")

    def append(self, rec: dict) -> None:
        token, api = self._session()
        name = f"hwm-{rec['gen']:06d}-{rec['epoch']:012d}-{rec.get('om', 0):09d}-{_fp_to_name(rec['fp'])}.json"
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
        got = _rpc("ffm_sender_attest", {"p_hwm_gen": mark["gen"], "p_hwm_epoch": mark["epoch"], "p_hwm_instance": mark["fp"]})
    except Exception as e:
        return {"ok": False, "reason": "database_unreachable", "detail": type(e).__name__}
    if not isinstance(got, dict) or got.get("ok") is not True:
        return {"ok": False, "reason": (got or {}).get("reason", "unexpected_answer") if isinstance(got, dict) else "unexpected_answer", "detail": str((got or {}).get("detail", ""))[:200] if isinstance(got, dict) else ""}
    ep = got.get("epoch")
    if isinstance(ep, int) and ep > mark["epoch"]:
        try:
            write_mark(_rec(mark["gen"], ep, mark["fp"] or got.get("instance_fp"), mark.get("om", 0)))
        except GateMarkError as e:
            return {"ok": False, "reason": "hwm_unavailable", "detail": str(e)[:160]}     # cannot record what we saw: do not send on it
    return {"ok": True, "epoch": ep, "open": bool(got.get("open"))}


def observe() -> dict:
    """Call right after the bot records a withdrawal / opt-out: advance the mark to the epoch that write produced, so a restore to a point just before it is detectable."""
    return attest(force=True)


def next_step(st: dict | None, mark: dict | None, stores_ok: bool = True) -> str:
    """The ONE next thing the owner must do, in order. Pure function (tested): record the restore -> verify -> anchor."""
    if not stores_ok:
        return "configure a mark store: GATE_HWM_FILE (a volume path) and/or BACKUP_PUT_URL=b2://... with BACKUP_AUTH"
    if not isinstance(st, dict) or st.get("epoch") is None:
        return "apply the migrations (the database has no suppression epoch), then verify the suppression list"
    rolled_back = bool(mark) and st["epoch"] < mark["epoch"]
    unused_owner_marker = int(st.get("last_owner_marker_id") or 0) > int((mark or {}).get("om", 0))
    if rolled_back and not unused_owner_marker:
        return ("the database is BEHIND this sender's mark (restore or rollback). Step 1: as the owner run select public.ffm_owner_record_restore('<what was restored>') "
                "(ops/OWNER_CONSENT_INTEGRITY.sql section 0); step 2: re-verify the suppression list; step 3: /gate anchor")
    if not st.get("core_ok"):
        return ("verify the suppression list as the owner (ops/OWNER_CONSENT_INTEGRITY.sql), then /gate anchor" if rolled_back else
                "verify the suppression list as the owner (ops/OWNER_CONSENT_INTEGRITY.sql)" + ("" if mark else ", then /gate anchor"))
    if rolled_back or mark is None:
        return "/gate anchor"
    if not st.get("open"):
        return "none: the gate is verified; the next engine tick (300 s) or send attests it"
    return "none"


def anchor(by: str = "owner") -> dict:
    """OWNER ACTION (called by /gate anchor). Starts a NEW generation at the database's current epoch. Order of the owner's steps: ffm_owner_record_restore -> verify -> anchor.
    Refused unless the gate is freshly verified AFTER the newest restore marker (ffm_gate_core_ok). If the database epoch is BELOW our mark (a restore), it is also refused unless an
    owner-recorded restore marker newer than the one this mark consumed exists: the anchor can never lower the mark after an undetected provider restore. The database makes the
    same decision against its own stored mark; this is the sender-side half, which still holds if the database's copy was rolled back too."""
    for attempt in range(3):      # the anchor must carry the CURRENT epoch exactly; a write between the read and the call is retried
        try:
            st = _rpc("ffm_gate_state")
        except Exception as e:
            return {"ok": False, "reason": "database_unreachable", "detail": type(e).__name__}
        if not isinstance(st, dict) or not isinstance(st.get("epoch"), int):
            return {"ok": False, "reason": "no_epoch", "detail": "the database has no suppression epoch (migration not applied or schema restored without it)"}
        if st.get("core_ok") is not True:
            return {"ok": False, "reason": "gate_not_verified", "detail": next_step(st, None)}
        try:
            cur = read_mark(True)
        except GateMarkError as e:
            return {"ok": False, "reason": "hwm_unavailable", "detail": str(e)[:160]}
        om = int(st.get("last_owner_marker_id") or 0)
        if cur and st["epoch"] < cur["epoch"] and om <= int(cur.get("om", 0)):
            return {"ok": False, "reason": "restore_not_recorded", "detail": "the database epoch (%s) is below this sender's mark (%s) and no owner-recorded restore is pending. %s" % (st["epoch"], cur["epoch"], next_step(st, cur))}
        gen = (cur["gen"] + 1) if cur else max(1, int(st.get("mark_gen") or 0) + 1)
        try:
            got = _rpc("ffm_sender_attest", {"p_hwm_gen": gen, "p_hwm_epoch": st["epoch"], "p_hwm_instance": st.get("instance_fp")})
        except Exception as e:
            return {"ok": False, "reason": "database_unreachable", "detail": type(e).__name__}
        if isinstance(got, dict) and got.get("ok") is True:
            break
        if isinstance(got, dict) and "exactly the current database epoch" in str(got.get("detail", "")) and attempt < 2:
            continue
        return {"ok": False, "reason": (got or {}).get("reason", "unexpected_answer") if isinstance(got, dict) else "unexpected_answer", "detail": str((got or {}).get("detail", ""))[:200] if isinstance(got, dict) else ""}
    else:
        return {"ok": False, "reason": "epoch_moving", "detail": "the database epoch kept changing; retry"}
    err = None
    for _ in range(3):            # the database accepted this generation: record it outside (a failure here is reported, never ignored)
        try:
            write_mark(_rec(gen, st["epoch"], st.get("instance_fp"), om)); err = None
            break
        except GateMarkError as e:
            err = e
    if err:
        return {"ok": False, "reason": "hwm_unavailable", "detail": "the database accepted generation %d but the store write failed (%s): record another owner restore and anchor again" % (gen, str(err)[:120])}
    try:
        hq._request("POST", "/rest/v1/audit_log", {"actor": by, "action": "ffm_sender_anchored", "target": "gate/1", "detail": {"epoch": st["epoch"], "generation": gen}}, prefer="return=minimal")
    except Exception:
        pass
    return {"ok": True, "epoch": st["epoch"], "generation": gen}


def status_lines() -> list:
    out, mark, st, ss = [], None, None, []
    try:
        ss = stores()
        out.append("stores: " + (", ".join(s.kind for s in ss) or "NONE configured (outreach stays closed)"))
        mark = read_mark(True)
        out.append("mark: " + (f"generation {mark['gen']}, epoch {mark['epoch']}, owner restore marker consumed {mark.get('om', 0)}" if mark else "none (sender unanchored: outreach stays closed)"))
        for s_ in ss:
            if getattr(s_, "hides", 0):
                out.append(f"WARNING: {s_.hides} hide marker(s) under the B2 gate/ prefix (hidden uploads still count; find out who or what hid them)")
            if getattr(s_, "foreign", 0):
                out.append(f"WARNING: {s_.foreign} unexpected object(s) under the B2 gate/ prefix (ignored)")
    except Exception as e:
        out.append(f"mark: unreadable ({str(e)[:120]}): outreach stays closed")
    try:
        st = _rpc("ffm_gate_state")
        out.append(f"database: epoch {st.get('epoch')}, gate {'OPEN' if st.get('open') else 'closed'} ({st.get('state')}), core {'ok' if st.get('core_ok') else 'not ok'}, newest restore marker {st.get('last_marker_id')}, stored mark generation {st.get('mark_gen')}")
    except Exception as e:
        out.append(f"database: unreachable or migration not applied ({type(e).__name__})")
    out.append("NEXT STEP: " + next_step(st, mark, bool(ss)))
    return out
