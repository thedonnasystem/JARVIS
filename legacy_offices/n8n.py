"""Jarvis -> n8n (the owner's self-hosted n8n, repo thedonnasystem/n8n-railway) through n8n's public REST API.

  /n8n templates                      the vetted starter templates and their parameters
  /n8n new <request in plain words>   pick a template (brain, else keywords), fill parameters, validate, import INACTIVE
  /n8n new <template-id> key=value .. explicit form: no brain needed
  /n8n list                           workflows and whether each is active
  /n8n activate <id>                  returns a one-time code; nothing changes yet
  /n8n confirm <code>                 the owner confirms: the workflow is activated
  /n8n deactivate <id>                immediate (turning things off is always allowed)

Rules:
  * Workflows are built ONLY from the vetted templates in legacy_offices/n8n_templates/ (the brain picks a template and
    fills its parameters; it never writes node JSON). validate() refuses any node type outside ALLOWED_NODES (no
    Code / Function / Execute Command / SSH / file nodes), embedded credentials, an 'active' flag, unfilled parameters,
    non-https URLs and broken connections.
  * Everything is imported inactive. Activation needs a one-time code from /n8n activate, confirmed with /n8n confirm
    within 10 minutes (single use, bound to that workflow id).
  * The owner's request is OWNER text, so it is sent to hq_llm declared as private (sources ["system", "owner_request"]).
    hq_llm then allows only a self-hosted model. Without one, the keyword matcher picks the template and nothing is sent.
Env: N8N_BASE_URL (https), N8N_API_KEY (from the n8n UI: Settings -> n8n API). Never logged.
"""
from __future__ import annotations

import json
import os
import re
import secrets
import time
import urllib.error
import urllib.request

from legacy_offices import redact

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_DIR = os.path.join(HERE, "n8n_templates")
ALLOWED_NODES = frozenset({
    "n8n-nodes-base.webhook", "n8n-nodes-base.telegram", "n8n-nodes-base.scheduleTrigger", "n8n-nodes-base.httpRequest",
    "n8n-nodes-base.if", "n8n-nodes-base.formTrigger", "n8n-nodes-base.googleSheets", "n8n-nodes-base.rssFeedRead",
    "n8n-nodes-base.limit", "n8n-nodes-base.set", "n8n-nodes-base.filter", "n8n-nodes-base.merge", "n8n-nodes-base.noOp",
})
PLACEHOLDER = re.compile(r"<<([a-z_]+)>>")
CONFIRM_TTL = 600
_pending: dict[str, tuple[str, float]] = {}   # code -> (workflow id, expiry)


class N8nError(Exception):
    """Safe to show: never contains the API key."""


# ------------------------------------------------------------------------------------------------------------------- templates
def templates() -> dict[str, dict]:
    out = {}
    for f in sorted(os.listdir(TEMPLATE_DIR)):
        if f.endswith(".json"):
            with open(os.path.join(TEMPLATE_DIR, f), encoding="utf-8") as fh:
                t = json.load(fh)
            out[t["id"]] = t
    return out


def missing_params(t: dict, params: dict) -> list[str]:
    return [k for k, spec in t["params"].items() if spec.get("required") and not str(params.get(k) or "").strip()]


def bad_params(t: dict, params: dict) -> list[str]:
    out = []
    for k, v in params.items():
        spec = t["params"].get(k)
        if spec is None:
            out.append(f"{k}: not a parameter of {t['id']}")
        elif spec.get("pattern") and not re.fullmatch(spec["pattern"], str(v)):
            out.append(f"{k}: does not match {spec['pattern']}")
        elif len(str(v)) > 300 or re.search(r"[<>]|\{\{|\$\(", str(v)):
            out.append(f"{k}: too long or contains template / expression characters")
    return out


def render(t: dict, params: dict) -> dict:
    vals = {k: str(params.get(k, spec.get("default", ""))) for k, spec in t["params"].items()}

    def sub(x):
        if isinstance(x, str):
            m = PLACEHOLDER.fullmatch(x)
            if m:   # a whole-value placeholder keeps the number type n8n expects (hour, items)
                v = vals.get(m.group(1), x)
                return int(v) if v.isdigit() and m.group(1) in ("hour", "items") else v
            return PLACEHOLDER.sub(lambda mm: vals.get(mm.group(1), mm.group(0)), x)
        if isinstance(x, list):
            return [sub(i) for i in x]
        if isinstance(x, dict):
            return {k: sub(v) for k, v in x.items()}
        return x
    return sub(json.loads(json.dumps(t["workflow"])))


def validate(wf: dict) -> list[str]:
    """Problems that block the import ([] = ok)."""
    p = []
    if not isinstance(wf, dict) or not str(wf.get("name") or "").strip():
        return ["workflow has no name"]
    if wf.get("active"):
        p.append("'active' must not be set: workflows are imported inactive")
    nodes = wf.get("nodes")
    if not isinstance(nodes, list) or not nodes or len(nodes) > 20:
        p.append("1 to 20 nodes required")
        return p
    names = [n.get("name") for n in nodes]
    if len(set(names)) != len(names):
        p.append("node names must be unique")
    for n in nodes:
        if n.get("type") not in ALLOWED_NODES:
            p.append(f"node type {n.get('type')} is not on the allowed list")
        if n.get("credentials"):
            p.append(f"node {n.get('name')}: credentials are attached in the n8n UI, never in the workflow JSON")
    blob = json.dumps(wf)
    if PLACEHOLDER.search(blob):
        p.append("unfilled parameters: " + ", ".join(sorted(set(PLACEHOLDER.findall(blob)))))
    if re.search(r"http://", blob):
        p.append("plain http URL: https only")
    for src, outs in (wf.get("connections") or {}).items():
        if src not in names:
            p.append(f"connection from unknown node {src}")
        for branch in (outs.get("main") or []):
            for c in branch or []:
                if c.get("node") not in names:
                    p.append(f"connection to unknown node {c.get('node')}")
    if not isinstance(wf.get("settings"), dict):
        p.append("settings object required by the n8n API")
    return p


# ------------------------------------------------------------------------------------------------------------------- choosing a template
def keyword_pick(text: str) -> str | None:
    t = (text or "").lower()
    best, hits = None, 0
    for tid, tpl in templates().items():
        n = sum(1 for k in tpl.get("keywords", []) if k in t)
        if n > hits:
            best, hits = tid, n
    return best


PICK_SYSTEM = ("Choose ONE n8n starter template for the owner's request and fill its parameters. Reply with JSON only: "
               "{\"template\": \"<id>\", \"params\": {...}}. Use only these templates; leave a parameter out if the request does not give it.\n")


def brain_pick(text: str, complete=None) -> tuple[str | None, dict, str]:
    """-> (template id, params, how). Brain first (private route: only a self-hosted model may take owner text), keywords otherwise."""
    cat = {tid: {"title": t["title"], "params": {k: v["desc"] for k, v in t["params"].items()}} for tid, t in templates().items()}
    if complete is None:
        try:
            import hq_llm
            complete = hq_llm.complete
        except Exception:
            complete = None
    if complete is not None:
        try:
            r = complete(PICK_SYSTEM + json.dumps(cat), [{"role": "user", "content": redact.text(text)[:1500]}],
                         division="n8n", task_class="n8n_template_pick", tier="small", sources=["system", "owner_request"], max_output=300)
            m = re.search(r"\{.*\}", (r or {}).get("text") or "", re.S)
            j = json.loads(m.group(0)) if m else {}
            if j.get("template") in cat:
                return j["template"], {k: str(v) for k, v in (j.get("params") or {}).items()}, "brain"
        except Exception:   # refused (no self-hosted model), offline or bad JSON: fall back, never fail the command
            pass
    return keyword_pick(text), {}, "keywords"


# ------------------------------------------------------------------------------------------------------------------- REST client
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def _http(method: str, path: str, body=None, env=None, opener=None):
    e = os.environ if env is None else env
    base, key = (e.get("N8N_BASE_URL") or "").rstrip("/"), e.get("N8N_API_KEY") or ""
    if not base or not key:
        raise N8nError("n8n is not connected: set N8N_BASE_URL and N8N_API_KEY (owner, after deploying n8n)")
    if not base.startswith("https://"):
        raise N8nError("N8N_BASE_URL must be https")
    req = urllib.request.Request(f"{base}/api/v1{path}", method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"X-N8N-API-KEY": key, "Content-Type": "application/json", "Accept": "application/json"})
    try:
        with (opener or _OPENER).open(req, timeout=20) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as err:
        raise N8nError(f"n8n answered {err.code} on {method} {path}") from None
    except (urllib.error.URLError, TimeoutError, ValueError) as err:
        raise N8nError(f"n8n unreachable ({type(err).__name__})") from None


def list_workflows(http=_http) -> list[dict]:
    return [{"id": w.get("id"), "name": w.get("name"), "active": bool(w.get("active"))} for w in (http("GET", "/workflows") or {}).get("data", [])]


def import_inactive(wf: dict, http=_http) -> dict:
    probs = validate(wf)
    if probs:
        raise N8nError("not imported: " + "; ".join(probs))
    body = {k: wf[k] for k in ("name", "nodes", "connections", "settings")}
    res = http("POST", "/workflows", body)
    if res.get("active"):   # never expected; if it ever happens, switch it straight off
        http("POST", f"/workflows/{res.get('id')}/deactivate")
    return res


def request_activation(wf_id: str, now=time.time) -> str:
    if not re.fullmatch(r"[A-Za-z0-9]{1,40}", str(wf_id or "")):
        raise N8nError("bad workflow id")
    code = secrets.token_hex(3)
    _pending[code] = (str(wf_id), now() + CONFIRM_TTL)
    return code


def confirm_activation(code: str, http=_http, now=time.time) -> str:
    item = _pending.pop(str(code or "").strip(), None)
    if not item or item[1] < now():
        raise N8nError("no pending activation for that code (expired or already used)")
    http("POST", f"/workflows/{item[0]}/activate")
    return item[0]


def deactivate(wf_id: str, http=_http) -> None:
    if not re.fullmatch(r"[A-Za-z0-9]{1,40}", str(wf_id or "")):
        raise N8nError("bad workflow id")
    http("POST", f"/workflows/{wf_id}/deactivate")


# ------------------------------------------------------------------------------------------------------------------- command text
USAGE = ("Usage: /n8n templates | /n8n new <what you want> | /n8n new <template-id> key=value ... | /n8n list | "
         "/n8n activate <id> | /n8n confirm <code> | /n8n deactivate <id>")


def command(args: list[str], http=_http, complete=None, now=time.time) -> str:
    if not args:
        return USAGE
    sub, rest = args[0].lower(), args[1:]
    try:
        if sub == "templates":
            return "n8n templates:\n" + "\n".join(
                f"- {tid}: {t['title']} | params: " + ", ".join(f"{k}{'' if s.get('required') else '?'}" for k, s in t["params"].items())
                for tid, t in templates().items())
        if sub == "list":
            ws = list_workflows(http)
            return "n8n workflows:\n" + ("\n".join(f"- {w['id']} {'ACTIVE' if w['active'] else 'inactive'} {w['name']}" for w in ws) or "(none)")
        if sub == "new":
            tpls = templates()
            kv = dict(a.split("=", 1) for a in rest if "=" in a)
            words = [a for a in rest if "=" not in a]
            if words and words[0] in tpls:
                tid, params, how = words[0], {}, "explicit"
            else:
                tid, params, how = brain_pick(" ".join(words), complete)
            if not tid:
                return "No template fits that request. /n8n templates lists what can be built."
            params.update(kv)
            t = tpls[tid]
            miss, bad = missing_params(t, params), bad_params(t, params)
            if miss or bad:
                return (f"Template {tid} ({t['title']}, chosen by {how}). " + (f"Missing: {', '.join(miss)}. " if miss else "")
                        + (f"Fix: {'; '.join(bad)}. " if bad else "")
                        + f"Send: /n8n new {tid} " + " ".join(f"{k}=..." for k in miss or t["params"]))
            wf = render(t, params)
            res = import_inactive(wf, http)
            return (f"Imported INACTIVE: {res.get('id')} \"{wf['name']}\" from {tid} (chosen by {how}). Attach credentials in n8n, then "
                    f"/n8n activate {res.get('id')}.")
        if sub == "activate" and rest:
            code = request_activation(rest[0], now)
            return f"To activate workflow {rest[0]}, send /n8n confirm {code} within 10 minutes. Nothing has changed yet."
        if sub == "confirm" and rest:
            return f"Activated workflow {confirm_activation(rest[0], http, now)}."
        if sub == "deactivate" and rest:
            deactivate(rest[0], http)
            return f"Deactivated workflow {rest[0]}."
    except N8nError as e:
        return str(e)
    return USAGE
