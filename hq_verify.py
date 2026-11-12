"""Deploy-and-verify: check that a public web page really is what an agent says it is (status, title, expected text, links).
Evidence for missions ("the site is live"), not trust. Public https only: private, loopback and link-local addresses are refused
(SSRF guard), redirects are re-checked, bodies are capped, nothing is stored or executed."""
from __future__ import annotations

import ipaddress
import re
import socket
import urllib.error
import urllib.parse
import urllib.request

MAX_BYTES = 400_000
TIMEOUT = 15
MAX_REDIRECTS = 3


def _public_host(host: str) -> bool:
    try:
        infos = socket.getaddrinfo(host, None)
    except OSError:
        return False
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast or ip.is_unspecified:
            return False
    return bool(infos)


def check_url(url: str) -> str | None:
    """-> reason it is refused, or None if allowed."""
    u = urllib.parse.urlparse((url or "").strip())
    if u.scheme != "https":
        return "Only https:// pages can be verified."
    if not u.hostname or u.username or u.password:
        return "Bad address."
    if u.port not in (None, 443):
        return "Only the standard https port is allowed."
    if not _public_host(u.hostname):
        return "That address is not a public website."
    return None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def _get(url: str):
    opener = urllib.request.build_opener(_NoRedirect)
    req = urllib.request.Request(url, headers={"User-Agent": "FendezyHQ-verify/1.0"})
    try:
        r = opener.open(req, timeout=TIMEOUT)
    except urllib.error.HTTPError as e:
        r = e
    body = r.read(MAX_BYTES + 1)
    return r.status if hasattr(r, "status") else r.code, dict(r.headers), body[:MAX_BYTES]


def verify(url: str, expect: list[str] | None = None) -> dict:
    """-> {ok, status, final_url, title, missing, problems}. Never raises."""
    current, hops = url, 0
    while True:
        why = check_url(current)
        if why:
            return {"ok": False, "problems": [why], "final_url": current}
        try:
            status, headers, body = _get(current)
        except Exception as e:
            return {"ok": False, "problems": [f"Could not load the page ({type(e).__name__})."], "final_url": current}
        if status in (301, 302, 303, 307, 308) and headers.get("Location"):
            hops += 1
            if hops > MAX_REDIRECTS:
                return {"ok": False, "problems": ["Too many redirects."], "final_url": current}
            current = urllib.parse.urljoin(current, headers["Location"])
            continue
        break
    text = body.decode("utf-8", "replace")
    m = re.search(r"<title[^>]*>(.*?)</title>", text, re.I | re.S)
    title = re.sub(r"\s+", " ", m.group(1)).strip() if m else ""
    low = text.lower()
    missing = [x for x in (expect or []) if x and x.lower() not in low]
    problems = []
    if status != 200:
        problems.append(f"HTTP {status}.")
    if not title:
        problems.append("No page title.")
    if missing:
        problems.append("Expected text not found: " + "; ".join(missing[:5]))
    return {"ok": not problems, "status": status, "final_url": current, "title": title[:120], "missing": missing, "problems": problems}


def report(url: str, expect: list[str] | None = None) -> str:
    r = verify(url, expect)
    if r["ok"]:
        return f"VERIFIED live: {r['final_url']} (HTTP {r['status']}, title \"{r['title']}\")" + (f", all {len(expect)} expected phrases found." if expect else ".")
    return f"NOT verified: {r['final_url']} " + " ".join(r["problems"])
