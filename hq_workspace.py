"""FF Marketing client-workspace helpers. The database is the enforcement point (migrations/20261117_client_workspaces_v1.sql);
this module only gives callers a pre-check and turns a refusal into a clear exception. Nothing here sends or spends anything."""
import json
import urllib.error

import hq


class SensitiveDataRefused(Exception):
    """The text looked like applications, banking, credit, ID or sensitive financial data. It was not stored and must not reach an AI."""


def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def _msg(e: urllib.error.HTTPError) -> str:
    try:
        b = json.loads(e.read().decode() or "{}")
        return str(b.get("message") or b)
    except Exception:
        return f"HTTP {e.code}"


def sensitive_hits(text: str) -> list:
    return list(_rpc("ws_sensitive_hits", {"p_text": text or ""}) or [])


def screen(*texts) -> None:
    """Call BEFORE passing any client text to a model. Raises if any text looks sensitive."""
    for t in texts:
        h = sensitive_hits(t) if t else []
        if h:
            raise SensitiveDataRefused(", ".join(h))


def add_lead(workspace: str, campaign, name, email=None, phone=None, source=None, note=None):
    try:
        return _rpc("ws_add_lead", {"p_ws": workspace, "p_campaign": campaign, "p_name": name, "p_email": email,
                                    "p_phone": phone, "p_source": source, "p_note": note})
    except urllib.error.HTTPError as e:
        m = _msg(e)
        if "Sensitive data refused" in m:
            raise SensitiveDataRefused(m) from None
        raise
