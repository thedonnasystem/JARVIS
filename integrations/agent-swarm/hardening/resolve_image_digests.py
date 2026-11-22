#!/usr/bin/env python3
"""resolve_image_digests.py: READ-ONLY registry digest resolver and drift reporter for the Swarm pilot images. Stdlib only.

For every image reference in the compose file, the Dockerfile (`# syntax=` and ARG ...IMAGE) and any --extra refs it asks the registry
(anonymous pull token, HTTPS, manifests and one config blob only; never pulls layers, never runs anything) for:
  index digest (what `image: name:tag@sha256:...` should carry), per-platform digests, image creation time, attestation presence,
and compares with what the file pins: CURRENT (pin == registry), DRIFT (tag now points elsewhere), PLACEHOLDER, UNPINNED.
It does NOT verify signatures (use cosign where a publisher signs; agent-swarm images carry BuildKit provenance only).
Usage: resolve_image_digests.py [--compose docker-compose.hardened.yml] [--dockerfile worker/Dockerfile.worker-hardened]
                               [--extra postgres:16 ...] [--min-age-days 14] [--fail-on-drift]
Exit 0 normally; 1 with --fail-on-drift and drift/placeholder; 2 on a registry/network error (never reads as success).
Writes a markdown table to stdout and to $GITHUB_STEP_SUMMARY when set. Registries: docker.io, ghcr.io (anonymous tokens only).
"""
import argparse
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request

ACCEPT = ",".join(["application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json",
                   "application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"])
REF = re.compile(r"^(?:(?P<host>ghcr\.io|docker\.io)/)?(?P<repo>[a-z0-9._/-]+?)(?::(?P<tag>[\w.-]+))?(?:@(?P<digest>sha256:[0-9a-f]{64}))?$")
ZERO = re.compile(r"^sha256:(0{64}|[0-9a-f]{0,6}x*)$")


def http(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=30) as f:
            return f.status, {k.lower(): v for k, v in f.headers.items()}, f.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()


def parse(ref):
    m = REF.match(ref)
    if not m:
        raise ValueError(f"unsupported reference: {ref}")
    host, repo, tag, dig = m.group("host") or "docker.io", m.group("repo"), m.group("tag") or "latest", m.group("digest")
    if host == "docker.io" and "/" not in repo:
        repo = "library/" + repo
    return host, repo, tag, dig


def token(host, repo):
    url = {"docker.io": f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull",
           "ghcr.io": f"https://ghcr.io/token?service=ghcr.io&scope=repository:{repo}:pull"}[host]
    st, _, body = http(url)
    if st != 200:
        raise RuntimeError(f"token {host}/{repo}: HTTP {st}")
    return json.loads(body)["token"]


def resolve(ref):
    host, repo, tag, pinned = parse(ref)
    base = "https://registry-1.docker.io" if host == "docker.io" else f"https://{host}"
    h = {"Accept": ACCEPT, "Authorization": "Bearer " + token(host, repo)}
    st, hd, body = http(f"{base}/v2/{repo}/manifests/{tag}", h)
    if st != 200:
        raise RuntimeError(f"{ref}: manifest HTTP {st}")
    m = json.loads(body)
    out = {"ref": ref, "registry_digest": hd.get("docker-content-digest"), "pinned": pinned, "platforms": {}, "attested": False, "created": None}
    amd = None
    for e in m.get("manifests", []):
        p = e.get("platform", {})
        if p.get("os") == "unknown" or "attestation-manifest" == (e.get("annotations") or {}).get("vnd.docker.reference.type"):
            out["attested"] = True
            continue
        k = f'{p.get("os")}/{p.get("architecture")}{("/" + p["variant"]) if p.get("variant") else ""}'
        out["platforms"][k] = e["digest"]
        if k == "linux/amd64":
            amd = e["digest"]
    if amd:
        st, _, b = http(f"{base}/v2/{repo}/manifests/{amd}", h)
        cfg = json.loads(b)["config"]["digest"] if st == 200 else None
        if cfg:
            st, _, b = http(f"{base}/v2/{repo}/blobs/{cfg}", {"Authorization": h["Authorization"]})
            if st == 200:
                out["created"] = json.loads(b).get("created")
    return out


def refs_from(compose, dockerfile, extra):
    refs = []
    if compose and os.path.isfile(compose):
        for line in open(compose):
            m = re.match(r"^\s*image:\s*([^\s#]+)", line)
            if m and not m.group(1).startswith("sha256:"):
                refs.append(("compose", m.group(1)))
    if dockerfile and os.path.isfile(dockerfile):
        txt = open(dockerfile).read()
        s = re.match(r"#\s*syntax\s*=\s*(\S+)", txt)
        if s:
            refs.append(("dockerfile syntax", s.group(1)))
        for a in re.finditer(r"(?m)^ARG\s+\w*IMAGE\w*=(\S+)", txt):
            refs.append(("dockerfile ARG", a.group(1)))
    refs += [("extra", e) for e in extra]
    return refs


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--compose", default=os.path.join(here, "docker-compose.hardened.yml"))
    ap.add_argument("--dockerfile", default=os.path.join(here, "worker", "Dockerfile.worker-hardened"))
    ap.add_argument("--extra", nargs="*", default=[])
    ap.add_argument("--min-age-days", type=int, default=14, help="flag images created more recently than this (brand-new tags)")
    ap.add_argument("--fail-on-drift", action="store_true")
    a = ap.parse_args(argv)
    rows, bad, err = [], 0, 0
    now = datetime.datetime.now(datetime.timezone.utc)
    for where, ref in refs_from(a.compose, a.dockerfile, a.extra):
        try:
            r = resolve(ref)
        except Exception as e:
            rows.append(f"| {where} | `{ref}` | ERROR | {e} | | | |")
            err += 1
            continue
        pin = r["pinned"]
        state = "UNPINNED" if not pin else "PLACEHOLDER" if ZERO.match(pin.split(":", 1)[1] and pin) else "CURRENT" if pin == r["registry_digest"] else "DRIFT"
        if state != "CURRENT":
            bad += 1
        age = ""
        if r["created"]:
            try:
                d = datetime.datetime.fromisoformat(r["created"].replace("Z", "+00:00"))
                days = (now - d).days
                age = f"{days}d" + (" NEW" if days < a.min_age_days else "")
            except ValueError:
                age = r["created"]
        plats = ", ".join(f"{k} `{v[7:19]}`" for k, v in sorted(r["platforms"].items()))
        rows.append(f"| {where} | `{ref.split('@')[0]}` | {state} | `{r['registry_digest']}` | {age} | {'yes' if r['attested'] else 'no'} | {plats} |")
    out = ["| source | image | pin state | registry index digest (put after @) | age | BuildKit attestation | platform digests |", "|---|---|---|---|---|---|---|"] + rows
    text = "\n".join(out)
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("### Image digests (read-only registry query)\n\n" + text + "\n")
    if err:
        return 2
    return 1 if (a.fail_on_drift and bad) else 0


if __name__ == "__main__":
    sys.exit(main())
