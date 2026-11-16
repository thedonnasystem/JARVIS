#!/usr/bin/env python3
"""Independent Oversight audit trail: an append-only, hash-chained JSONL ledger (docs/oversight/CHARTER.md section 6).

One JSON object per line in ops/oversight/ledger/reviews.jsonl. Every entry carries
    seq         1, 2, 3 ... with no gap
    prev_hash   entry_hash of the previous line (64 zeros for the first)
    entry_hash  sha256 of the canonical JSON of the entry without entry_hash
so an edit, a deletion or a reordering of any earlier line breaks the chain. A cut at the END of the file (or a full
rewrite with recomputed hashes) is NOT visible from the file alone: `verify --base-ref` / `--base-file` check that an
anchored copy is a byte prefix of this one, and `verify --expect-head` checks the last hash against one the Owner kept.
Canonical JSON = sorted keys, no spaces, ASCII only (non-ASCII is written as \\uXXXX), one line, "\\n" terminated.

Entry types
    review            a human/agent review: reviewer != author is enforced here and re-checked by verify
    mechanical_check  a run of mandatory_checks.py (never counts as an independent review)
    import            a review imported from a reviewer's report file (evidence = file sha256), marked not re-verified
    continuation      first line only: this file continues a sealed, broken ledger file (RUNBOOK section 7)
    owner_decision    ONLY valid with an Ed25519 signature made with a key listed in ops/oversight/owner_keys.json.
                      The signature covers the WHOLE entry (every field except signature / seq / prev_hash / entry_hash),
                      unknown fields are refused, and the decision is bound to one reviewed head: subject.sha must be the
                      sha of the entry named by review_id, and review_hash must be that entry's entry_hash (which commits
                      the whole chain before it), so a decision cannot be replayed onto another review or another ledger.
                      The oversight agent holds no key, so it cannot record "owner approved". With no key registered
                      (today), no owner decision can be recorded at all.
Owner keys (owner_keys.json): {"key_id", "ed25519_public_b64", optional "revoked_after_seq": N}. A revoked key still
    verifies the decisions it signed at seq <= N and can sign nothing after N. Never delete a key that signed an entry:
    deleting it makes those entries, and therefore the ledger, fail verification.

    ops/oversight/ledger.py verify [--base-ref <git ref>] [--base-file <path>] [--expect-head HASH]
    ops/oversight/ledger.py append --entry entry.json            (review / mechanical_check / import / continuation)
    ops/oversight/ledger.py owner-payload --review-id ID --decision approve|reject|defer --text "..." --sha <40 hex>
                                          --key-id K [--releases PROTECTED,PRODUCTION]     (prints what the Owner signs)
    ops/oversight/ledger.py append-owner --entry signed.json
Stdlib only, except signature verification, which needs `cryptography` (already in requirements/runtime.lock).
"""
import argparse
import base64
import binascii
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys

try:
    import fcntl
except ImportError:  # pragma: no cover  (non-POSIX: appending is refused, see append)
    fcntl = None

HERE = os.path.dirname(os.path.abspath(__file__))
LEDGER = os.path.join(HERE, "ledger", "reviews.jsonl")
OWNER_KEYS = os.path.join(HERE, "owner_keys.json")
GENESIS = "0" * 64
TYPES = ("review", "mechanical_check", "import", "owner_decision", "continuation")
RECOMMENDATIONS = ("APPROVE", "REJECT", "NEEDS_MORE_WORK")          # APPROVE = "recommend approval"; it authorises nothing
MECH_VERDICTS = ("RECOMMEND_APPROVE", "REJECT", "NEEDS_MORE_WORK")
OWNER_DECISIONS = ("approve", "reject", "defer")
RELEASABLE_CHECKS = ("PROTECTED", "PRODUCTION")     # the only checks whose owner-gate findings an owner decision can release
# every key below is refused on a non-owner entry. Keep in step with the SQL mirror proposal (docs/oversight/proposals/).
OWNER_ONLY_FIELDS = ("owner_decision", "owner_approved", "owner_signature", "decision", "signature", "key_id", "review_hash", "releases")
CHAIN_FIELDS = ("seq", "prev_hash", "entry_hash")
OWNER_FIELDS = ("type", "id", "ts", "subject", "review_id", "review_hash", "decision", "decision_text", "releases", "key_id", "signature")
REQUIRED = {"review": ("id", "ts", "subject", "reviewer", "author", "recommendation", "findings", "evidence"),
            "import": ("id", "ts", "subject", "reviewer", "author", "recommendation", "findings", "evidence"),
            "mechanical_check": ("id", "ts", "subject", "reviewer", "verdict", "evidence"),
            "continuation": ("id", "ts", "sealed_file", "sealed_sha256", "reason"),
            "owner_decision": ("id", "ts", "subject", "review_id", "review_hash", "decision", "decision_text", "releases", "key_id", "signature")}
HEX40, HEX64 = re.compile(r"^[0-9a-f]{40}$"), re.compile(r"^[0-9a-f]{64}$")
TS_RE = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")


def canonical(obj):
    """One ASCII line. ensure_ascii matters: U+2028 / U+2029 / U+0085 written raw would be split as line ends by some readers."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)


def entry_hash(entry):
    return hashlib.sha256(canonical({k: v for k, v in entry.items() if k != "entry_hash"}).encode("ascii")).hexdigest()


def owner_payload(entry):
    """The exact bytes the Owner signs: the canonical form of the FULL entry minus the signature and the three chain fields
    the ledger adds on append. Nothing in a stored owner decision is outside the signature."""
    return canonical({k: v for k, v in entry.items() if k != "signature" and k not in CHAIN_FIELDS}).encode("ascii")


def parse_owner_keys(text):
    """{key_id: {"pub": b64, "revoked_after_seq": int|None}} from owner_keys.json text. Anything malformed -> {} (fail closed)."""
    try:
        out = {}
        for k in json.loads(text or "").get("keys", []):
            kid, pub, rev = k["key_id"], k["ed25519_public_b64"], k.get("revoked_after_seq")
            if not (isinstance(kid, str) and kid and isinstance(pub, str)) or kid in out:
                return {}
            if rev is not None and (isinstance(rev, bool) or not isinstance(rev, int) or rev < 0):
                return {}
            out[kid] = {"pub": pub, "revoked_after_seq": rev}
        return out
    except (ValueError, KeyError, TypeError, AttributeError):
        return {}


def load_owner_keys(path=OWNER_KEYS):
    try:
        with open(path, encoding="utf-8") as f:
            return parse_owner_keys(f.read())
    except OSError:
        return {}


def _key(keys, kid):
    k = keys.get(kid) if isinstance(kid, str) else None
    return {"pub": k, "revoked_after_seq": None} if isinstance(k, str) else k      # plain {id: b64} maps are accepted too


def verify_owner_signature(entry, keys, seq=None):
    """None when valid, else the reason. Fails closed: no key, revoked key, no library, bad signature -> reason.
    seq: position of the entry (the next free seq when appending); a key revoked after seq N signs nothing beyond N."""
    kid = entry.get("key_id")
    k = _key(keys, kid)
    if not k:
        return f"owner key {kid!r} is not registered in owner_keys.json"
    rev = k.get("revoked_after_seq")
    if rev is not None and (seq is None or seq > rev):
        return f"owner key {kid!r} was revoked after seq {rev}; it cannot sign entry seq {seq}"
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ImportError:
        return "cannot verify the owner signature: python package `cryptography` is not installed (fail closed)"
    try:
        sig = base64.b64decode(entry.get("signature") or "", validate=True)
        if len(sig) != 64:
            raise ValueError("an Ed25519 signature is 64 bytes")
        Ed25519PublicKey.from_public_bytes(base64.b64decode(k["pub"], validate=True)).verify(sig, owner_payload(entry))
    except Exception:
        return "owner signature does not verify"
    return None


def _id(v):
    return isinstance(v, str) and bool(v.strip()) and len(v) <= 200


def validate(entry, keys, index=None, seq=None):
    """Content rules for one entry. index: {id: entry} of the entries before it (needed to bind an owner decision to its
    review; None = not checked). seq: its position. Returns a list of errors."""
    errs, t = [], entry.get("type")
    if not isinstance(t, str) or t not in TYPES:
        return [f"unknown type {t!r}"]
    for k in REQUIRED[t]:
        if k not in entry:
            errs.append(f"missing field {k}")
    if not _id(entry.get("id")):
        errs.append("id must be a non-empty string")
    if not (isinstance(entry.get("ts"), str) and TS_RE.match(entry["ts"])):
        errs.append("ts must be a UTC timestamp like 2026-11-16T02:07:52Z")
    if t == "continuation":
        if seq not in (None, 1):
            errs.append("a continuation entry is only valid as the first line of a new ledger file")
        if not (isinstance(entry.get("sealed_sha256"), str) and HEX64.match(entry["sealed_sha256"])):
            errs.append("sealed_sha256 must be the 64-hex sha256 of the sealed file")
        if not (_id(entry.get("sealed_file")) and _id(entry.get("reason"))):
            errs.append("sealed_file and reason must be non-empty strings")
        return errs + [f"field '{k}' is reserved for owner_decision entries" for k in OWNER_ONLY_FIELDS if k in entry]
    sub = entry.get("subject")
    if not isinstance(sub, dict) or not (isinstance(sub.get("sha"), str) and HEX40.match(sub["sha"])):
        errs.append("subject.sha must be a full 40-hex commit SHA")
        sub = {}
    if t == "owner_decision":
        for k in entry:
            if k not in OWNER_FIELDS and k not in CHAIN_FIELDS:
                errs.append(f"field '{k}' is not allowed in an owner decision (every field must be one the Owner signed for)")
        if entry.get("decision") not in OWNER_DECISIONS:
            errs.append("decision must be approve / reject / defer")
        if not isinstance(entry.get("decision_text"), str):
            errs.append("decision_text must be a string")
        rel = entry.get("releases")
        if not (isinstance(rel, list) and all(isinstance(r, str) and r in RELEASABLE_CHECKS for r in rel) and len(set(rel)) == len(rel)):
            errs.append(f"releases must be a list drawn from {RELEASABLE_CHECKS} (may be empty)")
        elif rel and entry.get("decision") != "approve":
            errs.append("only an approve decision can release anything")
        if not _id(entry.get("review_id")) or not _id(entry.get("key_id")):
            errs.append("review_id and key_id must be non-empty strings")
        elif index is not None:
            ref = index.get(entry["review_id"])
            if ref is None:
                errs.append(f"owner decision refers to entry {entry['review_id']} which is not earlier in the ledger")
            elif ref.get("type") == "owner_decision" or not isinstance(ref.get("subject"), dict):
                errs.append("an owner decision must refer to a review, import or mechanical_check entry")
            else:
                if ref.get("entry_hash") != entry.get("review_hash"):
                    errs.append("review_hash is not the entry_hash of the entry named by review_id (decision replayed onto another review or ledger?)")
                if ref["subject"].get("sha") != sub.get("sha"):
                    errs.append("subject.sha differs from the head SHA of the entry named by review_id (a decision is valid for one exact head)")
        why = verify_owner_signature(entry, keys, seq)
        if why:
            errs.append(why)
        return errs
    for k in OWNER_ONLY_FIELDS:
        if k in entry:
            errs.append(f"field '{k}' is reserved for owner_decision entries: a {t} entry cannot carry an owner decision")
    rid = (entry.get("reviewer") or {}).get("id") if isinstance(entry.get("reviewer"), dict) else None
    if not _id(rid):
        errs.append("reviewer.id is required (a non-empty string)")
    if t in ("review", "import"):
        aid = (entry.get("author") or {}).get("id") if isinstance(entry.get("author"), dict) else None
        if not _id(aid):
            errs.append("author.id is required (a non-empty string)")
        elif _id(rid) and " ".join(aid.split()).casefold() == " ".join(rid.split()).casefold():
            errs.append("reviewer.id equals author.id: self-review is not a review")
        if entry.get("recommendation") not in RECOMMENDATIONS:
            errs.append(f"recommendation must be one of {RECOMMENDATIONS}")
        ev = entry.get("evidence")
        if not isinstance(ev, list):
            errs.append("evidence must be a list")
            ev = []
        for item in ev:
            if not isinstance(item, dict) or not _id(item.get("ref")):
                errs.append("each evidence item needs a ref")
            elif "sha256" in item and not (isinstance(item["sha256"], str) and HEX64.match(item["sha256"])):
                errs.append("an evidence sha256 must be 64 lowercase hex characters")
        if t == "import" and not (entry.get("imported") is True and entry.get("re_verified") is False and ev
                                  and all(isinstance(e, dict) and isinstance(e.get("sha256"), str) and HEX64.match(e["sha256"]) for e in ev)):
            errs.append("an import entry must say imported=true, re_verified=false and give the sha256 of each evidence file")
    if t == "mechanical_check" and entry.get("verdict") not in MECH_VERDICTS:
        errs.append(f"verdict must be one of {MECH_VERDICTS}")
    return errs


def verify_text(text, keys=None):
    """(entries, errors) for ledger text. Detects edits, deletions, reordering, bad content, unsigned owner decisions."""
    keys = load_owner_keys() if keys is None else keys
    entries, errs, prev, index = [], [], GENESIS, {}
    if text and not text.endswith("\n"):
        errs.append("ledger does not end with a newline (truncated write?)")
    lines = text.split("\n")[:-1] if text.endswith("\n") else (text.split("\n") if text else [])     # "\n" only: never splitlines()
    for n, line in enumerate(lines, 1):
        try:
            e = json.loads(line)
            if not isinstance(e, dict):
                raise ValueError("not an object")
            canon = canonical(e)
        except ValueError as ex:
            errs.append(f"line {n}: not valid JSON ({ex})")
            prev = None
            continue
        if line != canon:
            errs.append(f"line {n}: not in canonical form (edited by hand?)")
        if e.get("seq") != n or isinstance(e.get("seq"), bool):
            errs.append(f"line {n}: seq is {e.get('seq')!r}, expected {n} (entry deleted, inserted or reordered)")
        if e.get("prev_hash") != prev:
            errs.append(f"line {n}: prev_hash does not match the previous entry (chain broken: edit, deletion or reordering)")
        if e.get("entry_hash") != entry_hash(e):
            errs.append(f"line {n}: entry_hash does not match the content (entry edited)")
        errs += [f"line {n}: {x}" for x in validate(e, keys, index, n)]
        eid = e.get("id")
        if isinstance(eid, str):
            if eid in index:
                errs.append(f"line {n}: duplicate id {eid}")
            index.setdefault(eid, e)
        prev = e.get("entry_hash")
        entries.append(e)
    return entries, errs


def verify_file(path=LEDGER, keys=None):
    try:
        with open(path, encoding="utf-8", newline="") as f:
            return verify_text(f.read(), keys)
    except (OSError, UnicodeDecodeError) as e:
        return [], [f"cannot read {path}: {e}"]


def head_hash(entries):
    return entries[-1]["entry_hash"] if entries else GENESIS


def append(entry, path=LEDGER, keys=None, now=None):
    """Append one entry under an exclusive file lock. Refuses when the existing ledger does not verify or the entry breaks a
    rule; re-verifies the file after writing and takes its own line back if that fails. Returns the stored entry."""
    if fcntl is None:
        raise ValueError("no file locking on this platform; append refused (run it on Linux/macOS)")
    keys = load_owner_keys() if keys is None else keys
    if not isinstance(entry, dict):
        raise ValueError("entry refused: not a JSON object")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "a+", encoding="utf-8", newline="") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)          # one writer at a time; released when the file closes
        f.seek(0)
        text = f.read()
        entries, errs = verify_text(text, keys)
        if errs:
            raise ValueError("existing ledger does not verify; refusing to append (repair: docs/oversight/RUNBOOK.md section 7): " + "; ".join(errs[:3]))
        e = {k: v for k, v in entry.items() if k not in CHAIN_FIELDS}
        e.setdefault("ts", (now or datetime.datetime.now(datetime.timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        index = {x["id"]: x for x in entries}
        if isinstance(e.get("id"), str) and e["id"] in index:
            raise ValueError(f"duplicate id {e.get('id')}")
        try:
            canonical(e)
        except (ValueError, TypeError) as ex:
            raise ValueError(f"entry refused: not representable as canonical JSON ({ex})")
        bad = validate(e, keys, index, len(entries) + 1)
        if bad:
            raise ValueError("entry refused: " + "; ".join(bad))
        e["seq"], e["prev_hash"] = len(entries) + 1, head_hash(entries)
        e["entry_hash"] = entry_hash(e)
        size = f.seek(0, os.SEEK_END)
        f.write(canonical(e) + "\n")
        f.flush()
        os.fsync(f.fileno())
        f.seek(0)
        after, errs = verify_text(f.read(), keys)
        if errs or len(after) != len(entries) + 1:
            f.truncate(size)                            # undo only our own unfinished line; earlier bytes are never touched
            f.flush()
            raise ValueError("entry refused: the ledger would not verify after writing it: " + "; ".join(errs[:3]))
    return e


def main(argv=None):
    ap = argparse.ArgumentParser(description="Oversight ledger: verify / append.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("verify")
    v.add_argument("--file", default=LEDGER), v.add_argument("--base-ref"), v.add_argument("--base-file"), v.add_argument("--expect-head")
    v.add_argument("--owner-keys", default=OWNER_KEYS, help="owner_keys.json to trust (default: the one next to this script)")
    a = sub.add_parser("append")
    a.add_argument("--file", default=LEDGER), a.add_argument("--entry", required=True)
    o = sub.add_parser("append-owner")
    o.add_argument("--file", default=LEDGER), o.add_argument("--entry", required=True)
    p = sub.add_parser("owner-payload")
    p.add_argument("--file", default=LEDGER)
    p.add_argument("--review-id", required=True), p.add_argument("--decision", required=True, choices=OWNER_DECISIONS)
    p.add_argument("--text", required=True), p.add_argument("--sha", required=True), p.add_argument("--pr", type=int), p.add_argument("--key-id", required=True)
    p.add_argument("--releases", default="", help="comma list of checks whose owner-gate findings this approval releases: " + ",".join(RELEASABLE_CHECKS))
    p.add_argument("--id"), p.add_argument("--ts")
    args = ap.parse_args(argv)
    if args.cmd == "verify":
        entries, errs = verify_file(args.file, load_owner_keys(args.owner_keys))
        base = None
        if args.base_ref and not errs:
            top = subprocess.run(["git", "-C", os.path.dirname(os.path.abspath(args.file)) or ".", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
            rel = os.path.relpath(os.path.realpath(args.file), os.path.realpath(top.stdout.strip() or ".")).replace(os.sep, "/")
            r = subprocess.run(["git", "-C", top.stdout.strip() or ".", "show", f"{args.base_ref}:{rel}"], capture_output=True)
            if top.returncode != 0 or r.returncode != 0:
                print(f"note: no ledger at {rel} on {args.base_ref} (nothing to compare)")
            else:
                base = (r.stdout, f"the ledger on {args.base_ref}")
        if args.base_file and not errs:
            try:
                with open(args.base_file, "rb") as f:
                    base = (f.read(), f"the ledger in {args.base_file}")
            except OSError as ex:
                errs.append(f"cannot read --base-file: {ex}")
        if base and not errs:
            with open(args.file, "rb") as f:
                if not f.read().startswith(base[0]):
                    errs.append(f"{base[1]} is not a prefix of this ledger (entries edited, removed or rewritten)")
        if args.expect_head and head_hash(entries) != args.expect_head:
            errs.append(f"head hash is {head_hash(entries)}, expected {args.expect_head} (ledger truncated or rewritten)")
        for e in errs:
            print("LEDGER ERROR:", e)
        print(f"{len(entries)} entries, head {head_hash(entries)}: {'FAILED' if errs else 'OK'}")
        return 1 if errs else 0
    if args.cmd == "owner-payload":
        entries, errs = verify_file(args.file)
        ref = {e["id"]: e for e in entries}.get(args.review_id)
        if errs or ref is None or (ref.get("subject") or {}).get("sha") != args.sha:
            print("REFUSED: the ledger does not verify, or it has no entry with that id for that exact SHA. "
                  "An owner decision is bound to one recorded review / mechanical check of one head.", file=sys.stderr)
            return 1
        releases = [r for r in args.releases.split(",") if r]
        e = {"type": "owner_decision", "id": args.id or f"OD-{args.review_id}", "ts": args.ts or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "subject": {"sha": args.sha, **({"pr": args.pr} if args.pr else {})}, "review_id": args.review_id, "review_hash": ref["entry_hash"],
             "decision": args.decision, "decision_text": args.text, "releases": releases, "key_id": args.key_id}
        print(json.dumps({"entry_without_signature": e, "payload_to_sign_b64": base64.b64encode(owner_payload(e)).decode()}, indent=1))
        return 0
    try:
        with open(args.entry, encoding="utf-8") as f:
            entry = json.load(f)
    except (OSError, ValueError) as ex:
        print("REFUSED: cannot read the entry file:", ex, file=sys.stderr)
        return 1
    if not isinstance(entry, dict) or (args.cmd == "append-owner") != (entry.get("type") == "owner_decision"):
        print("use `append-owner` for owner_decision entries and `append` for everything else", file=sys.stderr)
        return 1
    try:
        e = append(entry, args.file)
    except (ValueError, OSError, binascii.Error) as ex:
        print("REFUSED:", ex, file=sys.stderr)
        return 1
    print(f"appended seq {e['seq']} id {e['id']} hash {e['entry_hash']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
