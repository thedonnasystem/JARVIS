"""The ONE place the legacy offices start a process: a legacy repo's own tests or its dry-run / demo job, in a local clone.

Isolation (the reason this is its own small file for owner review):
  * the child gets an EMPTY environment plus PATH, HOME, LANG and the office's declared dry-run flags. Jarvis's own variables (database keys, bot
    token, provider keys) are never passed, so a legacy script cannot read or spend them;
  * argv is a list from the office JSON (no shell), the working directory must sit inside the clone, and every run has a timeout;
  * output is cut to the last lines and secret-looking strings are redacted before anything is returned.
It never runs in production: there are no clones there (LEGACY_SRC_DIR unset), so the doctor falls back to remote checks.
"""
from __future__ import annotations

import os
import subprocess

from legacy_offices import redact

SAFE_KEYS = ("PATH", "HOME", "LANG", "TMPDIR", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "HTTPS_PROXY", "https_proxy", "NO_PROXY", "no_proxy")
FORBIDDEN_FLAGS = ("KEY", "TOKEN", "SECRET", "PASS", "AUTH", "COOKIE")


def child_env(extra: dict | None = None, base: dict | None = None) -> dict:
    """PATH/HOME/... from the parent, the declared flags, nothing else. A declared flag that looks like a credential is refused."""
    src = os.environ if base is None else base
    env = {k: src[k] for k in SAFE_KEYS if k in src}
    for k, v in (extra or {}).items():
        if any(w in k.upper() for w in FORBIDDEN_FLAGS):
            raise ValueError(f"dry-run flag {k} looks like a credential: refused")
        env[str(k)] = str(v)
    return env


def run(argv: list[str], root: str, cwd: str = ".", extra_env: dict | None = None, timeout: int = 600, tail: int = 25) -> dict:
    """-> {rc, ok, out (redacted tail), timeout}. rc None = could not start or timed out."""
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
        raise ValueError("argv must be a non-empty list of strings")
    root = os.path.realpath(root)
    wd = os.path.realpath(os.path.join(root, cwd))
    if wd != root and not wd.startswith(root + os.sep):
        raise ValueError("cwd escapes the clone")
    try:
        p = subprocess.run(argv, cwd=wd, env=child_env(extra_env), capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return {"rc": None, "ok": False, "out": f"timed out after {timeout} s", "timeout": True}
    except OSError as e:
        return {"rc": None, "ok": False, "out": f"could not start: {type(e).__name__}", "timeout": False}
    lines = ((p.stdout or "") + "\n" + (p.stderr or "")).strip().splitlines()[-tail:]
    return {"rc": p.returncode, "ok": p.returncode == 0, "out": redact.text("\n".join(lines)), "timeout": False}
