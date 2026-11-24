#!/usr/bin/env python3
"""Donna.AI demo line on Retell (one agent: sales + multi-industry demo): build, validate and (optionally) push the config.

    python3 retell_push.py build      # prompts + agents.json -> retell/*.json (import-ready request bodies, placeholders kept)
    python3 retell_push.py validate   # check retell/*.json against Retell's published OpenAPI schema (schema/retell_openapi_subset.json)
    python3 retell_push.py push       # DRY RUN: shows what would be sent. Add --apply to send, --publish to also publish the drafts.

push reads everything from environment variables; no key or id is ever written to a file:
    RETELL_API_KEY                 required for push
    DONNA_DEMO_AGENT_ID            update this existing agent (the one on the demo number) instead of creating one (optional)
    DONNA_MAKE_WEBHOOK_URL         Make.com custom-webhook URL for call summaries and texts (optional; omitted if unset)
    DONNA_FOUNDER_MOBILE           +1XXXXXXXXXX for the sales agent's transfer tool (optional; the tool is dropped if unset)
When updating an existing agent, its voice is kept (Kate) unless --set-voice is given.
Standard library only. Untested against the live API from this repo (no key here): run without --apply first.
"""
import argparse
import copy
import json
import os
import re
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
API = "https://api.retellai.com"
PH = re.compile(r"\$\{([A-Z0-9_]+)\}")
ORDER = ("demo_line",)


def load_source() -> dict:
    with open(os.path.join(HERE, "agents.json"), encoding="utf-8") as f:
        return json.load(f)["agents"]


def bodies(name: str, spec: dict) -> tuple[dict, dict]:
    """-> (Retell LLM request body, agent request body) with the prompt inlined and ${...} placeholders kept."""
    with open(os.path.join(HERE, spec["prompt_file"]), encoding="utf-8") as f:
        prompt = f.read().strip()
    llm = {**copy.deepcopy(spec["llm"]), "general_prompt": prompt}
    agent = {**copy.deepcopy(spec["agent"]), "response_engine": {"type": "retell-llm", "llm_id": "${LLM_ID}"}}
    return llm, agent


def build() -> list[str]:
    out = os.path.join(HERE, "retell")
    os.makedirs(out, exist_ok=True)
    written = []
    for name, spec in load_source().items():
        llm, agent = bodies(name, spec)
        for kind, body in (("llm", llm), ("agent", agent)):
            p = os.path.join(out, f"{name}.{kind}.json")
            with open(p, "w", encoding="utf-8") as f:
                f.write(json.dumps(body, ensure_ascii=False, indent=2) + "\n")
            written.append(os.path.relpath(p, HERE))
    return written


# ------------------------------------------------------------------------------------------------------------- validation
def _schema() -> dict:
    with open(os.path.join(HERE, "schema", "retell_openapi_subset.json"), encoding="utf-8") as f:
        return json.load(f)


def _props(doc: dict, name: str) -> set:
    """Top-level property names allowed by a component (following allOf), to catch misspelt fields the schema would ignore."""
    s = doc["components"]["schemas"][name]
    keys = set(s.get("properties", {}))
    for part in s.get("allOf", []):
        if "$ref" in part:
            keys |= _props(doc, part["$ref"].rsplit("/", 1)[1])
        keys |= set(part.get("properties", {}))
    return keys


def problems(body: dict, root: str) -> list[str]:
    """Problems with one request body against Retell's schema (root: CreateAgentBody | RetellLlmBody)."""
    doc = _schema()
    out = []
    allowed = _props(doc, "AgentRequest") | {"is_transfer_agent"} if root == "CreateAgentBody" else _props(doc, "RetellLlmRequest")
    out += [f"unknown field {k!r}" for k in body if k not in allowed]
    try:
        import jsonschema
    except ImportError:                                   # still useful without jsonschema: required fields and unknown keys
        req = {"CreateAgentBody": ("response_engine", "voice_id"), "RetellLlmBody": ("start_speaker",)}[root]
        return out + [f"missing {k}" for k in req if k not in body]
    v = jsonschema.Draft7Validator({**doc, "$ref": f"#/roots/{root}"})
    for e in sorted(v.iter_errors(body), key=lambda e: list(e.absolute_path)):
        out.append(f"{'/'.join(map(str, e.absolute_path)) or '(root)'}: {e.message[:300]}")
    return out


def validate() -> dict:
    res = {}
    for name in load_source():
        for kind, root in (("llm", "RetellLlmBody"), ("agent", "CreateAgentBody")):
            p = os.path.join(HERE, "retell", f"{name}.{kind}.json")
            with open(p, encoding="utf-8") as f:
                res[f"{name}.{kind}"] = problems(json.load(f), root)
    return res


# ------------------------------------------------------------------------------------------------------------- push
def fill(body, env: dict, required: set):
    """Replace ${NAME} from env. A tool or field whose placeholder is unset is dropped, unless its name is in `required`."""
    if isinstance(body, dict):
        out = {}
        for k, v in body.items():
            names = set(PH.findall(json.dumps(v)))
            missing = {n for n in names if not env.get(n)}
            if missing and isinstance(v, str):
                if missing & required:
                    raise SystemExit(f"set {', '.join(sorted(missing & required))} first")
                continue                                  # optional field, e.g. webhook_url
            out[k] = fill(v, env, required)
        return out
    if isinstance(body, list):
        kept = []
        for item in body:
            missing = {n for n in PH.findall(json.dumps(item)) if not env.get(n)}
            if missing and not (missing & required) and isinstance(item, dict) and "type" in item and "name" in item:
                print(f"  note: tool {item['name']!r} left out ({', '.join(sorted(missing))} not set)")
                continue
            kept.append(fill(item, env, required))
        return kept
    if isinstance(body, str):
        return PH.sub(lambda m: env[m.group(1)] if env.get(m.group(1)) else m.group(0), body)
    return body


def _call(method: str, path: str, key: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path}: HTTP {e.code} {e.read()[:500].decode(errors='replace')}") from None


def push(apply: bool, publish: bool, set_voice: bool, env=os.environ) -> None:
    key = env.get("RETELL_API_KEY", "")
    if apply and not key:
        raise SystemExit("set RETELL_API_KEY (Retell dashboard > Settings > API keys) in your shell; never paste it into a file")
    env = dict(env)
    src = load_source()
    for name in ORDER:
        spec = src[name]
        llm, agent = bodies(name, spec)
        agent_id = env.get(spec["env_agent_id"], "")
        llm = fill(llm, env, set())
        for label, b, root in (("llm", llm, "RetellLlmBody"), ("agent", {**agent, "response_engine": {"type": "retell-llm", "llm_id": "x"}}, "CreateAgentBody")):
            p = problems(fill(b, env, set()), root)
            if p:
                raise SystemExit(f"{name}.{label} does not match Retell's schema: {p}")
        print(f"[{name}] {'update agent ' + agent_id[:6] + '...' if agent_id else 'create new LLM + agent'}")
        if not apply:
            print(f"  dry run: would send LLM ({len(llm['general_prompt'])} chars of prompt, tools: {[t['name'] for t in llm.get('general_tools', [])]})")
            continue
        if agent_id:
            cur = _call("GET", f"/get-agent/{agent_id}", key)
            llm_id = (cur.get("response_engine") or {}).get("llm_id")
            if not llm_id:
                raise SystemExit(f"{name}: agent {agent_id[:6]}... is not a single-prompt (retell-llm) agent; paste the prompt in the dashboard instead")
            _call("PATCH", f"/update-retell-llm/{llm_id}", key, llm)
            upd = {k: v for k, v in fill(agent, env, set()).items() if k != "response_engine" and (set_voice or k != "voice_id")}
            done = _call("PATCH", f"/update-agent/{agent_id}", key, upd)
            if publish:
                _call("POST", f"/publish-agent-version/{agent_id}", key, {"version": done.get("version")})
            print(f"  updated{' and published' if publish else ' (draft: click Publish in the dashboard)'}")
        else:
            llm_id = _call("POST", "/create-retell-llm", key, llm)["llm_id"]
            new = _call("POST", "/create-agent", key, {**fill(agent, env, set()), "response_engine": {"type": "retell-llm", "llm_id": llm_id}})
            agent_id = new["agent_id"]
            print(f"  created agent {agent_id} (save it as {spec['env_agent_id']} in your shell, not in a file)")
        env[spec["env_agent_id"]] = agent_id


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("verb", choices=("build", "validate", "push"))
    ap.add_argument("--apply", action="store_true", help="push: actually send (default is a dry run)")
    ap.add_argument("--publish", action="store_true", help="push --apply: publish updated drafts")
    ap.add_argument("--set-voice", action="store_true", help="push: also overwrite the existing agent's voice")
    a = ap.parse_args(argv)
    if a.verb == "build":
        for p in build():
            print("wrote", p)
        return 0
    if a.verb == "validate":
        bad = 0
        for k, p in validate().items():
            print(f"{k}: {'OK' if not p else '; '.join(p)}")
            bad += bool(p)
        return 1 if bad else 0
    push(a.apply, a.publish, a.set_voice)
    return 0


if __name__ == "__main__":
    sys.exit(main())
