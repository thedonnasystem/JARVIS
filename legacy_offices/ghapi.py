"""Read-only GitHub REST for the legacy offices (commits, Actions runs, annotations). GET only; never writes.

Token: LEGACY_GITHUB_TOKEN (a read-only, fine-grained token on the legacy repos is enough), else GITHUB_TOKEN. Without one, every call returns
(None, reason) and the doctor reports the check as 'unknown'. The token is never logged or returned.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

API = "https://api.github.com"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A 3xx is not followed: urllib would re-send the Authorization header to whatever host the redirect names."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def token() -> str:
    return os.environ.get("LEGACY_GITHUB_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""


def get(path: str, timeout: int = 20):
    """-> (json or None, error text or None). path starts with '/'."""
    if not path.startswith("/"):
        raise ValueError("path must start with /")
    tok = token()
    if not tok:
        return None, "no GitHub token (LEGACY_GITHUB_TOKEN)"
    req = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {tok}", "Accept": "application/vnd.github+json",
                                                      "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "jarvis-office-doctor"})
    try:
        with _OPENER.open(req, timeout=timeout) as r:
            return json.loads(r.read().decode() or "null"), None
    except urllib.error.HTTPError as e:
        return None, f"GitHub {e.code}"
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        return None, f"GitHub unreachable ({type(e).__name__})"
