#!/usr/bin/env python3
"""Validator for the organization contract ops/org/divisions.json (see docs/org/ORG_ARCHITECTURE.md). Pure stdlib.

Two layers:
  1. structure: ops/org/divisions.schema.json, checked by the small JSON Schema subset interpreter below
     (type, const, enum, pattern, required, properties, additionalProperties, items, min/maxItems, uniqueItems,
     min/maxLength, minimum/maximum, local $ref). The schema file uses nothing outside that subset.
  2. safety rules that a schema cannot express (rule ids S1..S12). Contract version 1 is a PROPOSAL: every division is
     dormant, every budget is zero, every permission is deny-by-default with a dormant allow-list.

Usage
  scripts/org_contract.py                     validate; exit 0 clean, 1 findings
  scripts/org_contract.py --emit-seed         print the SQL seed block for migrations/20261123_org_divisions_v1.sql
  scripts/org_contract.py --check-migration   also fail if that migration's seed block differs from the contract
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CONTRACT = os.path.join(ROOT, "ops", "org", "divisions.json")
SCHEMA = os.path.join(ROOT, "ops", "org", "divisions.schema.json")
MIGRATION = os.path.join(ROOT, "migrations", "20261123_org_divisions_v1.sql")
SEED_BEGIN = "-- BEGIN GENERATED SEED (scripts/org_contract.py --emit-seed; do not edit by hand)"
SEED_END = "-- END GENERATED SEED"

# Capabilities no division may ever hold, whatever the contract file says. The contract's own list may add to this, never remove.
NEVER_DELEGABLE = ("kill_switch.", "spend_cap.", "budget.", "grant.", "delegation.", "division.", "permission.", "executor.",
                   "payment.", "bank.", "backup.", "deploy.", "migration.", "owner.", "privacy.", "consent.", "outbox.send",
                   "secret.", "agent.create", "agent.activate")
PII_PATTERNS = (
    ("email address", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")),
    ("phone number", re.compile(r"(?<![0-9])(?:\+?1[ .-]?)?\(?[0-9]{3}\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4}(?![0-9])")),
)
_TYPES = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}


def _is_type(value, name):
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, _TYPES[name])


def schema_errors(value, schema, root=None, path="$"):
    """Errors of `value` against `schema` (the subset listed in the module docstring)."""
    root = schema if root is None else root
    if "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        return schema_errors(value, node, root, path)
    errs = []
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(value, n) for n in names):
            return [f"{path}: expected {'/'.join(names)}"]
    if "const" in schema and (value != schema["const"] or type(value) is not type(schema["const"])):
        errs.append(f"{path}: must be {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errs.append(f"{path}: {value!r} is not one of {schema['enum']}")
    if isinstance(value, str):
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errs.append(f"{path}: {value!r} does not match {schema['pattern']}")
        if len(value) < schema.get("minLength", 0):
            errs.append(f"{path}: shorter than {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errs.append(f"{path}: longer than {schema['maxLength']}")
    if _is_type(value, "number"):
        if "minimum" in schema and value < schema["minimum"]:
            errs.append(f"{path}: below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errs.append(f"{path}: above {schema['maximum']}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errs.append(f"{path}: fewer than {schema['minItems']} items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errs.append(f"{path}: more than {schema['maxItems']} items")
        if schema.get("uniqueItems"):
            seen = [json.dumps(v, sort_keys=True) for v in value]
            if len(seen) != len(set(seen)):
                errs.append(f"{path}: items are not unique")
        if "items" in schema:
            for i, item in enumerate(value):
                errs += schema_errors(item, schema["items"], root, f"{path}[{i}]")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errs.append(f"{path}: missing {key!r}")
        for key, item in value.items():
            if key in props:
                errs += schema_errors(item, props[key], root, f"{path}.{key}")
            elif schema.get("additionalProperties") is False:
                errs.append(f"{path}: unexpected key {key!r}")
    return errs


def _strings(value, path="$"):
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from _strings(v, f"{path}[{i}]")
    elif isinstance(value, dict):
        for k, v in value.items():
            yield from _strings(v, f"{path}.{k}")


def never_delegable(cap, extra=()):
    return any(cap.startswith(p) for p in tuple(NEVER_DELEGABLE) + tuple(extra))


def rule_errors(doc):
    """Safety rules S1..S12. Assumes the document already passed the schema."""
    errs = []
    g = doc["global"]
    cap = g["ai_daily_cap_cents"]
    missing = [p for p in NEVER_DELEGABLE if p not in g["never_delegable_prefixes"]]
    if missing:
        errs.append(f"S1 global.never_delegable_prefixes drops built-in entries: {missing}")
    extra = g["never_delegable_prefixes"]
    catalog = [c["id"] for c in g["capability_catalog"]]
    if len(catalog) != len(set(catalog)):
        errs.append("S2 capability catalog has duplicate ids")
    for c in catalog:
        if never_delegable(c, extra):
            errs.append(f"S2 catalog capability {c} is on the never-delegable list")
    ids = [d["id"] for d in doc["divisions"]]
    if len(ids) != len(set(ids)):
        errs.append("S3 duplicate division id")
    if len({o["id"] for o in doc["corporate_offices"]}) != len(doc["corporate_offices"]):
        errs.append("S3 duplicate corporate office id")
    proposed_total = 0
    for d in doc["divisions"]:
        w = f"division {d['id']}"
        if d["status"] != "dormant":
            errs.append(f"S4 {w}: status is {d['status']!r}; contract version 1 allows only 'dormant' (activation is a separate owner-approved release)")
        b = d["budget"]
        if b["daily_envelope_cents"] != 0 or b["monthly_envelope_cents"] != 0:
            errs.append(f"S5 {w}: budget envelope must be zero while the division is not active")
        if b["proposed_daily_cents"] > cap:
            errs.append(f"S6 {w}: proposed daily envelope {b['proposed_daily_cents']} exceeds the global AI cap {cap}")
        proposed_total += b["proposed_daily_cents"]
        allowed = set()
        for a in d["delegated_permissions"]["allow"]:
            c = a["capability"]
            if c in allowed:
                errs.append(f"S7 {w}: capability {c} listed twice")
            allowed.add(c)
            if never_delegable(c, extra):
                errs.append(f"S8 {w}: capability {c} can never be delegated (self-escalation / protected control)")
            elif c not in catalog:
                errs.append(f"S7 {w}: capability {c} is not in the capability catalog")
            if a["status"] != "dormant":
                errs.append(f"S9 {w}: grant {c} has status {a['status']!r}; only 'dormant' is allowed in contract version 1")
            if a["scope"] == "own_workspaces" and d["isolation"]["client_workspace_access"] == "none":
                errs.append(f"S10 {w}: grant {c} is scoped to client workspaces but isolation says the division has none")
        if "workspace.read" in allowed and d["isolation"]["client_workspace_access"] != "own_workspaces_aggregate_only":
            errs.append(f"S10 {w}: workspace.read requires isolation.client_workspace_access = own_workspaces_aggregate_only")
        if d["isolation"]["reads_other_divisions"]:
            errs.append(f"S10 {w}: a division may not read other divisions")
        if d["manager"]["can_contact_owner"]:
            errs.append(f"S11 {w}: only Jarvis may contact the owner")
        roles = [d["manager"]["role_id"]] + [r["role_id"] for r in d["team"]]
        if len(roles) != len(set(roles)):
            errs.append(f"S3 {w}: duplicate role id")
        kpis = [k["id"] for k in d["kpis"]]
        if len(kpis) != len(set(kpis)):
            errs.append(f"S3 {w}: duplicate KPI id")
        tids = [t["id"] for t in d["mission_templates"]]
        if len(tids) != len(set(tids)):
            errs.append(f"S3 {w}: duplicate mission template id")
        for t in d["mission_templates"]:
            if t["status"] != "dormant":
                errs.append(f"S4 {w}: mission template {t['id']} must be dormant")
            if t["max_budget_cents"] != 0:
                errs.append(f"S5 {w}: mission template {t['id']} must have a zero budget")
            beyond = sorted(set(t["required_capabilities"]) - allowed)
            if beyond:
                errs.append(f"S8 {w}: mission template {t['id']} needs capabilities outside the division allow-list: {beyond}")
    if proposed_total > cap:
        errs.append(f"S6 proposed daily envelopes add up to {proposed_total}, above the global AI cap {cap}")
    for path, text in _strings(doc):
        for label, pat in PII_PATTERNS:
            if pat.search(text):
                errs.append(f"S12 {path}: looks like a {label}; the contract is exported and must hold no personal data")
    return errs


def validate(doc, schema):
    errs = schema_errors(doc, schema)
    return errs if errs else rule_errors(doc)


def _q(text):
    return "'" + text.replace("'", "''") + "'"


def emit_seed(doc):
    """The seed block of the migration: one dormant row per division, one dormant row per allow-list entry. Deterministic."""
    out = [SEED_BEGIN]
    divs = sorted(doc["divisions"], key=lambda d: d["id"])
    out.append("insert into public.org_divisions (slug, name, contract_version) values")
    out.append(",\n".join(f"  ({_q(d['id'])}, {_q(d['name'])}, {_q(doc['contract_version'])})" for d in divs))
    out.append("on conflict (slug) do nothing;")
    grants = [(d["id"], a["capability"], a["scope"]) for d in divs for a in sorted(d["delegated_permissions"]["allow"], key=lambda a: a["capability"])]
    if grants:
        out.append("insert into public.org_division_grants (division_slug, capability, scope) values")
        out.append(",\n".join(f"  ({_q(s)}, {_q(c)}, {_q(sc)})" for s, c, sc in grants))
        out.append("on conflict (division_slug, capability) do nothing;")
    out.append(SEED_END)
    return "\n".join(out)


def migration_seed(text):
    i, j = text.find(SEED_BEGIN), text.find(SEED_END)
    return None if i < 0 or j < 0 else text[i:j + len(SEED_END)]


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--contract", default=CONTRACT)
    ap.add_argument("--schema", default=SCHEMA)
    ap.add_argument("--emit-seed", action="store_true")
    ap.add_argument("--check-migration", action="store_true")
    args = ap.parse_args(argv)
    doc = load(args.contract)
    errs = validate(doc, load(args.schema))
    if not errs and args.check_migration:
        with open(MIGRATION, encoding="utf-8") as f:
            if migration_seed(f.read()) != emit_seed(doc):
                errs.append("the seed block in migrations/20261123_org_divisions_v1.sql differs from the contract (a new migration is needed; applied migrations are not edited)")
    for e in errs:
        print(e)
    if errs:
        print(f"ORG CONTRACT INVALID: {len(errs)} finding(s)")
        return 1
    if args.emit_seed:
        print(emit_seed(doc))
    else:
        print(f"org contract ok: {len(doc['divisions'])} divisions, all dormant, zero budget, default deny")
    return 0


if __name__ == "__main__":
    sys.exit(main())
