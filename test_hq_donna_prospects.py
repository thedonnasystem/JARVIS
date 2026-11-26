"""Tests for hq_donna_prospects (Donna Prospects v1). OpenStreetMap, pages and the database are mocked."""
import datetime as dt
import tempfile
import unittest

import hq_donna
import hq_donna_prospects as P

OSM = {"elements": [
    {"tags": {"name": "Pine Plumbing", "craft": "plumber", "website": "https://pineplumbing.example/"}},
    {"tags": {"name": "Ash Electric", "craft": "electrician", "contact:website": "http://ashelectric.example"}},
    {"tags": {"name": "No Site Co", "craft": "plumber", "email": "osm-only@nosite.example"}},
    {"tags": {"name": "Pine Plumbing (dup)", "craft": "plumber", "website": "https://pineplumbing.example/about"}},
]}


class Research:
    cfg = {"user_agent": "DonnaResearchBot/1.0"}

    def __init__(self, pages):
        self.pages, self.posted = pages, []

    def http(self, method, url, headers=None, form=None, timeout=0):
        self.posted.append((method, url, form))
        return 200, OSM, {}


class Ctx:
    run_id = "RUN"
    cfg = {"niches": ["plumbing", "electrical"]}

    def __init__(self, pages):
        self.research = Research(pages)
        self.added = []

    def check(self, a):
        assert a == "research"

    def rpc(self, name, args):
        assert name == "donna_add_prospect"
        self.added.append(args)
        return {"lead": "L" + str(len(self.added)), "duplicate": False}


class Find(unittest.TestCase):
    def test_query_and_candidates(self):
        q = P.query(["plumbing", "dental clinics"], "Ottawa")
        self.assertIn('nwr["craft"="plumber"]["website"](area.a)', q)
        self.assertIn('nwr["amenity"="dentist"]', q)
        c = P.candidates(OSM, ["plumbing", "electrical"])
        self.assertEqual([x["business"] for x in c], ["Pine Plumbing", "Ash Electric"], "one per host; no website = skipped (never the OSM email)")
        self.assertEqual(c[1]["url"], "https://ashelectric.example")
        self.assertIn('area["wikidata"="Q1930"]', P.query(["plumbing"], "Ottawa", wikidata="Q1930"), "the City of Ottawa, not every Ottawa")
        with self.assertRaises(hq_donna.DonnaRefused):
            P.query(["unknown niche"], "Ottawa")

    def test_contact_must_be_on_their_own_page(self):
        seen = []
        orig = hq_donna._prospect
        def fake(ctx, p):
            seen.append(p["url"])
            if p["url"] == "https://pineplumbing.example/contact":
                return ctx.rpc("donna_add_prospect", {"p_business": p["business"], "p_source_url": p["url"]}) and {"business": p["business"], "recorded": True, "lead": "L1"}
            if "ashelectric" in p["url"]:
                return {"business": p["business"], "recorded": False, "reason": "the page says no unsolicited messages"}
            return {"business": p["business"], "recorded": False, "reason": "no published contact on the page"}
        hq_donna._prospect = fake
        try:
            ctx = Ctx({})
            r = P.find_prospects(ctx, {"limit": 5})
        finally:
            hq_donna._prospect = orig
        self.assertEqual(seen, ["https://pineplumbing.example/", "https://pineplumbing.example/contact", "https://ashelectric.example"],
                         "home, then /contact; a no-solicit notice stops at once")
        self.assertEqual(r["recorded"], 1)
        self.assertEqual(ctx.research.posted[0][1], P.OVERPASS)
        self.assertIn("OpenStreetMap", r["source"])

    def test_once_a_day(self):
        with tempfile.TemporaryDirectory() as d:
            env, now = {"DONNA_STATE_DIR": d}, dt.datetime(2026, 11, 27, 9, 0)
            self.assertTrue(P.due_today(env, now))
            P.mark_today(env, now)
            self.assertFalse(P.due_today(env, now))
            self.assertTrue(P.due_today(env, now + dt.timedelta(days=1)))

    def test_dispatch(self):
        orig = P.find_prospects
        P.find_prospects = lambda ctx, inputs: {"mode": "find_prospects"}
        try:
            self.assertEqual(hq_donna.market_research(Ctx({}), {"mode": "find_prospects"})["mode"], "find_prospects")
        finally:
            P.find_prospects = orig


if __name__ == "__main__":
    unittest.main()
