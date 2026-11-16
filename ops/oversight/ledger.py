#!/usr/bin/env python3
"""Independent Oversight audit trail: an append-only, hash-chained JSONL ledger (docs/oversight/CHARTER.md section 6).

One JSON object per line in ops/oversight/ledger/reviews.jsonl. Every entry carries
    seq         1, 2, 3 ... with no gap
    prev_hash   entry_hash of the previous line (64 zeros for the first)
    entry_hash  sha256 of the canonical JSON of the entry without entry_hash
so an edit, a deletion or a reordering of any earlier line breaks the chain. A cut at the END of the file (or a full
rewrite with recomputed hashes) is NOT visible from the file alone: `verify --base-ref` checks that the ledger on a git ref
is a byte prefix of this one, and `verify --expect-head` checks the last hash against one the Owner kept.

Entry types
    review            a human/agent review: reviewer != author is enforced here and re-checked by verify
    mechanical_check  a run of mandatory_checks.py (never counts as an independent review)
    import            a review imported from a reviewer's report file (evidence = file sha256), marked not re-verified
    owner_decision    ONLY valid with an Ed25519 signature made with a key listed in ops/oversight/owner_keys.json.
                      The oversight agent holds no such key, so it cannot record "owner approved". With no key
                      registered (today), no owner decision can be recorded at all.

    ops/oversight/ledger.py verify [--base-ref origin/overnight-build] [--expect-head HASH]
    ops/oversight/ledger.py append --entry entry.json            (review / mechanical_check / import)
    ops/oversight/ledger.py owner-payload --review-id ID --decision approve|reject|defer --text "..."   (prints what the Owner signs)
    ops/oversight/ledger.py append-owner --entry signed.json
Stdlib only, except signature verification, which needs `cryptography` (already in requirements/runtime.lock).
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LEDGER = os.path.join(HERE, "ledger", "reviews.jsonl")
OWNER_KEYS = os.path.join(HERE, "owner_keys.json")
GENESIS = "0" * 64
TYPES = ("review", "mechanical_check", "import", "owner_decision")
RECOMMENDATIONS = ("APPROVE", "REJECT", "NEEDS_MORE_WORK")          # APPROVE = "recommend approval"; it authorises nothing
MECH_VERDICTS = ("RECOMMEND_APPROVE", "REJECT", "NEEDS_MORE_WORK")
OWNER_ONLY_FIELDS = ("owner_decision", "owner_approved", "owner_signature", "decision", "signature", "key_id")
REQUIRED = {"review": ("id", "ts", "subject", "reviewer", "author", "recommendation", "findings", "evidence"),
            "import": ("id", "ts", "subject", "reviewer", "author", "recommendation", "findings", "evidence"),
            "mechanical_check": ("id", "ts", "subject", "reviewer", "verdict", "evidence"),
            "owner_decision": ("id", "ts", "subject", "review_id", "decision", "decision_text", "key_id", "signature")}


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def entry_hash(entry):
    return hashlib.sha256(canonical({k: v for k, v in entry.items() if k != "entry_hash"}).encode()).hexdigest()


def owner_payload(entry):
    """The exact bytes the Owner signs: everything that makes the decision, nothing the ledger adds."""
    return canonical({k: entry.get(k) for k in ("type", "id", "ts", "subject", "review_id", "decision", "decision_text", "key_id")}).encode()


def load_owner_keys(path=OWNER_KEYS):
    try:
        with open(path) as f:
            return {k["key_id"]: k["ed25519_public_b64"] for k in json.load(f).get("keys", [])}
    except (OSError, ValueError, KeyError, TypeError):
        return {}


def verify_owner_signature(entry, keys):
    """None when valid, else the reason. Fails closed: no key, no library, bad signature -> reason."""
    pub = keys.get(entry.get("key_id"))
    if not pub:
        return f"owner key '{entry.get('key_id')}' is not registered in owner_keys.json"
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ImportError:
        return "cannot verify the owner signature: python package `cryptography` is not installed (fail closed)"
    try:
        Ed25519PublicKey.from_public_bytes(base64.b64decode(pub)).verify(base64.b64decode(entry.get("signature") or ""), owner_payload(entry))
    except Exception:
        return "owner signature does not verify"
    return None


def validate(entry, keys):
    """Content rules for one entry (independent of the chain). Returns a list of errors."""
    errs, t = [], entry.get("type")
    if t not in TYPES:
        return [f"unknown type {t!r}"]
    for k in REQUIRED[t]:
        if k not in entry:
            errs.append(f"missing field {k}")
    sub = entry.get("subject") or {}
    if not isinstance(sub, dict) or not (isinstance(sub.get("sha"), str) and len(sub["sha"]) == 40 and all(c in "0123456789abcdef" for c in sub["sha"])):
        errs.append("subject.sha must be a full 40-hex commit SHA")
    if t == "owner_decision":
        if entry.get("decision") not in ("approve", "reject", "defer"):
            errs.append("decision must be approve / reject / defer")
        why = verify_owner_signature(entry, keys)
        if why:
            errs.append(why)
        return errs
    for k in OWNER_ONLY_FIELDS:
        if k in entry:
            errs.append(f"field '{k}' is reserved for owner_decision entries: a {t} entry cannot carry an owner decision")
    rid = (entry.get("reviewer") or {}).get("id")
    if not rid:
        errs.append("reviewer.id is required")
    if t in ("review", "import"):
        aid = (entry.get("author") or {}).get("id")
        if not aid:
            errs.append("author.id is required")
        elif aid == rid:
            errs.append("reviewer.id equals author.id: self-review is not a review")
        if entry.get("recommendation") not in RECOMMENDATIONS:
            errs.append(f"recommendation must be one of {RECOMMENDATIONS}")
        for ev in entry.get("evidence") or []:
            if not isinstance(ev, dict) or not ev.get("ref"):
                errs.append("each evidence item needs a ref")
        if t == "import" and not (entry.get("imported") is True and entry.get("re_verified") is False
                                  and all(isinstance(e, dict) and len(str(e.get("sha256", ""))) == 64 for e in entry.get("evidence") or [None])):
            errs.append("an import entry must say imported=true, re_verified=false and give the sha256 of each evidence file")
    if t == "mechanical_check" and entry.get("verdict") not in MECH_VERDICTS:
        errs.append(f"verdict must be one of {MECH_VERDICTS}")
    return errs


def verify_text(text, keys=None):
    """(entries, errors) for ledger text. Detects edits, deletions, reordering, bad content, unsigned owner decisions."""
    keys = load_owner_keys() if keys is None else keys
    entries, errs, prev, ids = [], [], GENESIS, set()
    if text and not text.endswith("\n"):
        errs.append("ledger does not end with a newline (truncated write?)")
    for n, line in enumerate(text.splitlines(), 1):
        try:
            e = json.loads(line)
            if not isinstance(e, dict):
                raise ValueError("not an object")
        except ValueError as ex:
            errs.append(f"line {n}: not valid JSON ({ex})")
            prev = None
            continue
        if line != canonical(e):
            errs.append(f"line {n}: not in canonical form (edited by hand?)")
        if e.get("seq") != n:
            errs.append(f"line {n}: seq is {e.get('seq')}, expected {n} (entry deleted, inserted or reordered)")
        if e.get("prev_hash") != prev:
            errs.append(f"line {n}: prev_hash does not match the previous entry (chain broken: edit, deletion or reordering)")
        if e.get("entry_hash") != entry_hash(e):
            errs.append(f"line {n}: entry_hash does not match the content (entry edited)")
        if e.get("id") in ids:
            errs.append(f"line {n}: duplicate id {e.get('id')}")
        ids.add(e.get("id"))
        errs += [f"line {n}: {x}" for x in validate(e, keys)]
        if e.get("type") == "owner_decision" and e.get("review_id") not in ids:
            errs.append(f"line {n}: owner decision refers to review {e.get('review_id')} which is not earlier in the ledger")
        prev = e.get("entry_hash")
        entries.append(e)
    return entries, errs


def verify_file(path=LEDGER, keys=None):
    try:
        with open(path, encoding="utf-8") as f:
            return verify_text(f.read(), keys)
    except OSError as e:
        return [], [f"cannot read {path}: {e}"]


def head_hash(entries):
    return entries[-1]["entry_hash"] if entries else GENESIS


def append(entry, path=LEDGER, keys=None, now=None):
    """Append one entry. Refuses when the existing ledger does not verify or the entry breaks a rule. Returns the stored entry."""
    keys = load_owner_keys() if keys is None else keys
    text = ""
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            text = f.read()
    entries, errs = verify_text(text, keys)
    if errs:
        raise ValueError("existing ledger does not verify; refusing to append: " + "; ".join(errs[:3]))
    e = {k: v for k, v in entry.items() if k not in ("seq", "prev_hash", "entry_hash")}
    e.setdefault("ts", (now or datetime.datetime.now(datetime.timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ"))
    if any(x.get("id") == e.get("id") for x in entries):
        raise ValueError(f"duplicate id {e.get('id')}")
    bad = validate(e, keys)
    if e.get("type") == "owner_decision" and e.get("review_id") not in {x.get("id") for x in entries}:
        bad.append(f"review {e.get('review_id')} is not in the ledger")
    if bad:
        raise ValueError("entry refused: " + "; ".join(bad))
    e["seq"], e["prev_hash"] = len(entries) + 1, head_hash(entries)
    e["entry_hash"] = entry_hash(e)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(canonical(e) + "\n")
    return e


def main(argv=None):
    ap = argparse.ArgumentParser(description="Oversight ledger: verify / append.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("verify")
    v.add_argument("--file", default=LEDGER), v.add_argument("--base-ref"), v.add_argument("--expect-head")
    a = sub.add_parser("append")
    a.add_argument("--file", default=LEDGER), a.add_argument("--entry", required=True)
    o = sub.add_parser("append-owner")
    o.add_argument("--file", default=LEDGER), o.add_argument("--entry", required=True)
    p = sub.add_parser("owner-payload")
    p.add_argument("--review-id", required=True), p.add_argument("--decision", required=True, choices=("approve", "reject", "defer"))
    p.add_argument("--text", required=True), p.add_argument("--sha", required=True), p.add_argument("--pr", type=int), p.add_argument("--key-id", required=True)
    p.add_argument("--id"), p.add_argument("--ts")
    args = ap.parse_args(argv)
    if args.cmd == "verify":
        entries, errs = verify_file(args.file)
        if args.base_ref and not errs:
            rel = os.path.relpath(os.path.abspath(args.file), os.path.normpath(os.path.join(HERE, "..", "..")))
            r = subprocess.run(["git", "-C", HERE, "show", f"{args.base_ref}:{rel}"], capture_output=True, text=True)
            with open(args.file, encoding="utf-8") as f:
                cur = f.read()
            if r.returncode == 0 and not cur.startswith(r.stdout):
                errs.append(f"the ledger on {args.base_ref} is not a prefix of this ledger (entries edited, removed or rewritten)")
            elif r.returncode != 0:
                print(f"note: no ledger on {args.base_ref} (nothing to compare)")
        if args.expect_head and head_hash(entries) != args.expect_head:
            errs.append(f"head hash is {head_hash(entries)}, expected {args.expect_head} (ledger truncated or rewritten)")
        for e in errs:
            print("LEDGER ERROR:", e)
        print(f"{len(entries)} entries, head {head_hash(entries)}: {'FAILED' if errs else 'OK'}")
        return 1 if errs else 0
    if args.cmd == "owner-payload":
        e = {"type": "owner_decision", "id": args.id or f"OD-{args.review_id}", "ts": args.ts or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "subject": {"sha": args.sha, **({"pr": args.pr} if args.pr else {})}, "review_id": args.review_id, "decision": args.decision,
             "decision_text": args.text, "key_id": args.key_id}
        print(json.dumps({"entry_without_signature": e, "payload_to_sign_b64": base64.b64encode(owner_payload(e)).decode()}, indent=1))
        return 0
    with open(args.entry) as f:
        entry = json.load(f)
    if (args.cmd == "append-owner") != (entry.get("type") == "owner_decision"):
        print("use `append-owner` for owner_decision entries and `append` for everything else", file=sys.stderr)
        return 1
    try:
        e = append(entry, args.file)
    except ValueError as ex:
        print("REFUSED:", ex, file=sys.stderr)
        return 1
    print(f"appended seq {e['seq']} id {e['id']} hash {e['entry_hash']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
