"""Donna Prospects v1: Donna finds her own prospects, free, so the cold campaign never waits for a list.

  1. OpenStreetMap (Overpass API, free, no key; data (c) OpenStreetMap contributors, ODbL): businesses of Donna's niches in the owner's area that list a website.
  2. For each, Donna's existing prospect rule (hq_donna._prospect): the contact counts ONLY when it is verbatim on the business's OWN https page (home, /contact,
     /contact-us), robots.txt allows it, and the page has no "no unsolicited messages" notice (CASL conspicuous publication). An address that only OSM lists
     is never used.
  3. donna_add_prospect records it (deduplicated); the Revenue Loop then drafts the first email once a day, and the owner taps Approve.

market-research mode "find_prospects" (green: research). The tick runs it once a day with DONNA_PROSPECTING=1 (and DONNA_AUTODRAFT=1, Donna active),
at most `prospects_per_run` businesses a day. No model is used, and nothing is sent.
"""
from __future__ import annotations

import datetime as dt
import os
import urllib.parse

import hq_donna

OVERPASS = "https://overpass-api.de/api/interpreter"
FLAG = "DONNA_PROSPECTING"
NICHE_TAGS = {
    "hvac": [("craft", "hvac")], "plumbing": [("craft", "plumber")], "electrical": [("craft", "electrician")],
    "roofing and renovation": [("craft", "roofer"), ("craft", "carpenter")], "dental clinics": [("amenity", "dentist")],
    "hair and beauty salons": [("shop", "hairdresser"), ("shop", "beauty")], "law firms (intake only)": [("office", "lawyer")],
    "auto repair": [("shop", "car_repair")], "cleaning services": [("craft", "cleaning"), ("office", "cleaning")],
}


def cfg() -> dict:
    return hq_donna.config().get("prospecting") or {}


def query(niches: list[str], area: str, limit: int = 200, wikidata: str | None = None) -> str:
    sel = "".join(f'nwr["{k}"="{v}"]["website"](area.a);nwr["{k}"="{v}"]["contact:website"](area.a);'
                  for n in niches for k, v in NICHE_TAGS.get(n, []))
    if not sel:
        raise hq_donna.DonnaRefused("no OpenStreetMap tags for these niches")
    a = area.replace('"', "")[:60]
    sel_area = f'area["wikidata"="{wikidata}"]' if wikidata and wikidata[1:].isdigit() and wikidata[0] == "Q" else f'area["name"="{a}"]["boundary"="administrative"]'
    return f'[out:json][timeout:25];{sel_area}->.a;({sel});out tags {int(limit)};'


def candidates(body, niches: list[str]) -> list[dict]:
    out, seen = [], set()
    for e in (body or {}).get("elements") or [] if isinstance(body, dict) else []:
        t = e.get("tags") or {}
        url = str(t.get("website") or t.get("contact:website") or "").strip()
        if url.startswith("http://"):
            url = "https://" + url[7:]
        name = str(t.get("name") or "").strip()
        host = urllib.parse.urlsplit(url).hostname or ""
        if not (name and url.startswith("https://") and host) or host in seen:
            continue
        niche = next((n for n in niches for k, v in NICHE_TAGS.get(n, []) if t.get(k) == v), None)
        seen.add(host)
        out.append({"business": name[:120], "url": url, "niche": niche})
    return out


def pages(url: str) -> list[str]:
    p = urllib.parse.urlsplit(url)
    base = f"https://{p.hostname}"
    return list(dict.fromkeys([url, base + "/contact", base + "/contact-us"]))


def find_prospects(ctx, inputs: dict) -> dict:
    """market-research mode 'find_prospects'."""
    ctx.check("research")
    c = cfg()
    niches = [n for n in (inputs.get("niches") or c.get("niches") or ctx.cfg["niches"]) if n in NICHE_TAGS][:9]
    limit = min(int(inputs.get("limit") or c.get("prospects_per_run", 15)), 40)
    st, body, _ = ctx.research.http("POST", OVERPASS, headers={"User-Agent": ctx.research.cfg["user_agent"]},
                                    form={"data": query(niches, c.get("area", "Ottawa"), wikidata=c.get("area_wikidata"))}, timeout=40)
    if st != 200:
        raise hq_donna.DonnaRefused(f"OpenStreetMap returned HTTP {st}")
    found = candidates(body, niches)
    skip = set(inputs.get("skip_hosts") or [])
    done, tried = [], 0
    for cand in found:
        if len([d for d in done if d.get("recorded")]) >= limit or tried >= limit * 3:
            break
        if urllib.parse.urlsplit(cand["url"]).hostname in skip:
            continue
        tried += 1
        last = None
        for u in pages(cand["url"]):
            last = hq_donna._prospect(ctx, {"url": u, "business": cand["business"]})
            if last.get("recorded") or last.get("lead") or "no unsolicited" in str(last.get("reason")):
                break
        done.append({**(last or {}), "niche": cand["niche"], "url": cand["url"]})
    rec = [d for d in done if d.get("recorded")]
    return {"mode": "find_prospects", "candidates": len(found), "tried": tried, "recorded": len(rec), "results": done[:60],
            "source": "OpenStreetMap contributors (ODbL), contacts verified on each business's own site"}


def due_today(env: dict, now: dt.datetime) -> bool:
    try:
        with open(os.path.join(env.get("DONNA_STATE_DIR") or "/data", "donna_prospects_day.txt")) as f:
            return f.read().strip() != now.date().isoformat()
    except OSError:
        return True


def mark_today(env: dict, now: dt.datetime) -> None:
    try:
        d = env.get("DONNA_STATE_DIR") or "/data"
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "donna_prospects_day.txt"), "w") as f:
            f.write(now.date().isoformat())
    except OSError:
        pass
