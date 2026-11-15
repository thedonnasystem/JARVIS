"""hq_scrub: the engine-side scrubber for text stored in exported tables (tasks.result, escalations.summary, agent_runs.summary), and its use by hq_engine.
Covers direct input, indirect propagation (a name from a lead reply that comes back in a task result / escalation), encodings, obfuscation, Unicode look-alikes, French, and adversarial
splitting. Also proves what must NOT change (ids, amounts, clean text, accents) and that the task still completes with a scrubbed result."""
import base64, binascii, unittest
from unittest import mock

import hq, hq_engine as E, hq_scrub as S

KNOWN = S.Known(names=["Jean Tremblay", "Éloïse Bédard", "Marcus Zzyxwell", "Quillfeather Bakery", "Odalys Quenneville", "Wexcombe Holdings Ltd"],
                contacts=["613-555-0142", "514-555-0177", "marcus@setters.example"], emails=["jean.tremblay@tremblay-plomberie.ca", "odalys.q@quenneville-co.example"])


def squash(s):
    return "".join(ch for ch in S.fold(s).lower() if ch.isalnum())


def digits(s):
    return "".join(ch for ch in S.fold(s) if ch.isdigit())


EMAIL = "jean.tremblay@tremblay-plomberie.ca"
VECTORS = [   # (id, input, must-not-appear, expect: None | "uncertain")
    ("D1", f"Call Jean Tremblay on 613-555-0142 or {EMAIL}", ["tremblay", "#6135550142"], None),
    ("D2", "Marcus Zzyxwell was paid; Quillfeather Bakery closed; Wexcombe Holdings asked", ["zzyxwell", "quillfeather", "wexcombe"], None),
    ("D3", "Odalys Quenneville odalys.q@quenneville-co.example 819-555-0123", ["odalys", "quenneville", "#8195550123"], None),
    *[(f"P{i}", f"a {p} b", ["#6135550142"], None) for i, p in enumerate(["(613) 555-0142", "613.555.0142", "+1 613 555 0142", "6135550142", "1-613-555-0142", "613 555 01 42", "tel:+16135550142",
                                                                         "613,555,0142", "613_555_0142", "613 - 555 - 0142", "6 1 3 5 5 5 0 1 4 2"])],
    ("P20", "six one three five five five zero one four two", ["sixonethree"], None), ("P21", "appelez le six un trois cinq cinq cinq zéro un quatre deux", ["sixuntrois"], None),
    ("U1", "a ٦١٣-٥٥٥-٠١٤٢ b", ["#6135550142"], None), ("U2", "a ６１３－５５５－０１４２ b", ["#6135550142"], None), ("U3", "a ۶۱۳۵۵۵۰۱۴۲ b", ["#6135550142"], None), ("U4", "a ६१३५५५०१४२ b", ["#6135550142"], None),
    ("S2", "number 123 456 789 here", ["#123456789"], None), ("S3", "ref 123456789012345678 here", ["#123456789012345678"], None), ("S4", "acct 4111 1111 1111 1111", ["#4111111111111111"], None),
    ("E1", "mail jane.doe@example.com now", ["janedoe"], None), ("E2", "jane [at] example [dot] com", ["janeexamplecom"], None), ("E3", "jane (at) example (dot) com", ["janeexamplecom"], None),
    ("E4", "jane at example dot com", ["janeexamplecom"], None), ("E5", "jane @ example.com", ["janeexamplecom"], None), ("E6", "jane＠example.com", ["janeexamplecom"], None),
    ("E7", "jane{at}example{dot}com", ["janeexamplecom"], None), ("E8", "jane arobase example point com", ["janeexamplecom"], None), ("E10", "JANE@EXAMPLE.COM", ["janeexamplecom"], None),
    ("E11", "j a n e @ e x a m p l e . c o m", ["janeexamplecom"], "uncertain"), ("E12", "courriel : marie.cote@exemple.ca", ["mariecote"], None),
    ("E14", "ping @jane_doe_99 on instagram", ["janedoe99"], None), ("E15", "moc.elpmaxe@enaj", ["moc.elpmaxe@enaj"], None),
    ("X1", "x " + base64.b64encode(EMAIL.encode()).decode() + " y", ["tremblay", "amVhbi5"], None), ("X2", "x " + binascii.hexlify(EMAIL.encode()).decode() + " y", ["tremblay"], None),
    ("X3", "x 0x" + binascii.hexlify(EMAIL.encode()).decode() + " y", ["tremblay"], None), ("X4", "x jean.tremblay%40tremblay-plomberie.ca y", ["tremblay"], None),
    ("X5", "x jean.tremblay&#64;tremblay-plomberie.ca y", ["tremblay"], None), ("X6", "x jean.tremblay&#x40;tremblay-plomberie.ca y", ["tremblay"], None),
    ("X7", "x jean.tremblay&commat;tremblay-plomberie&period;ca y", ["tremblay"], None), ("X8", "x jean.tremblay\\u0040tremblay-plomberie.ca y", ["tremblay"], None),
    ("X9", "x jean.tremblay%2540tremblay-plomberie.ca y", ["tremblay"], None), ("X10", "x %4A%65%61%6E %54%72%65%6D%62%6C%61%79 y", ["tremblay"], None),
    ("X12", "x " + base64.b64encode(base64.b64encode(EMAIL.encode())).decode() + " y", ["tremblay"], None), ("X13", "x " + base64.urlsafe_b64encode(EMAIL.encode()).decode() + " y", ["tremblay"], None),
    ("X14", "x &#74;&#101;&#97;&#110; &#84;&#114;&#101;&#109;&#98;&#108;&#97;&#121; y", ["tremblay"], None),
    ("H1", "Jеаn Trеmblау", ["tremblay"], None), ("H2", "Ιean Τremblay", ["tremblay"], None), ("H3", "Je​an Trem‍blay", ["tremblay"], None), ("H4", "Trémblay", ["tremblay"], None),
    ("H5", "ＪＥＡＮ ＴＲＥＭＢＬＡＹ", ["tremblay"], None), ("H6", "Je­an Tremb﻿l⁠ay", ["tremblay"], None), ("H7", "Éloïse Bédard", ["bedard"], None), ("H8", "Eloise Bedard", ["bedard"], None),
    ("H10", "Éloïse Bédard", ["bedard"], None), ("H12", "𝐓𝐫𝐞𝐦𝐛𝐥𝐚𝐲 ⓙⓔⓐⓝ", ["tremblay"], None),
    ("F1", "appelez Jean Tremblay au 613-555-0142", ["tremblay", "#6135550142"], None), ("F2", f"courriel: {EMAIL} merci", ["tremblay"], None),
    ("F3", "Éloïse Bédard a dit: rappelez-moi au 514 555 0177 svp", ["bedard", "#5145550177"], None), ("F4", "le client Quillfeather Bakery a payé; téléphone (819) 555-0123", ["quillfeather", "#8195550123"], None),
    ("F5", "Écrivez à marie.cote [arobase] exemple [point] ca", ["mariecote"], None),
    ("V1", "J e a n   T r e m b l a y", ["jeantremblay"], "uncertain"), ("V2", "jEaN tReMbLaY", ["tremblay"], None), ("V3", "Tremblay, Jean", ["tremblay"], None), ("V4", "JEAN-TREMBLAY", ["tremblay"], None),
    ("V5", "jeantremblay", ["tremblay"], None), ("V6", "Tremblay", ["tremblay"], None), ("V8", "J.e.a.n T.r.e.m.b.l.a.y", ["jeantremblay"], "uncertain"), ("V9", "Tremb\nlay", ["tremblay"], "uncertain"),
    ("V11", "Q-u-i-l-l-f-e-a-t-h-e-r", ["quillfeather"], "uncertain"), ("V13", "WEXCOMBE   holdings", ["wexcombe"], None), ("V14", "jean.tremblay", ["tremblay"], None),
    ("L1", "see https://www.linkedin.com/in/jean-tremblay-1234 now", ["jean-tremblay"], None), ("L2", "https://example.com/contact?email=jane@example.com&name=Jane", ["jane@", "name=jane"], None),
    ("L3", "https://www.facebook.com/jean.tremblay.55", ["jean.tremblay"], None), ("L4", "https://tremblay-plomberie.ca/about", ["tremblay"], None), ("L5", "http://x.example/u/jean", ["/u/jean"], None),
]
KEEP = ["do_not_contact", "received", "deal 3f2a1b4c-1111-4222-8333-444455556666: owner confirmed win", "Setter payout (close): setter 3f2a1b4c-1111-4222-8333-444455556666",
        "Verified 3 suppliers; margin 12%; total $1,250.00; see https://acmeplumbing.ca/about", "2026-11-15T10:30:00Z", "Résumé des tâches: 3 terminées, 2 en cours, 40 000 $ prévus",
        "cap $3.30 per day; 12 of 40 done; status=blocked; 5 retries", "Spent 33 cents of 330 cents on 2026-11-15 (3f2a1b4c-1111-4222-8333-444455556666)",
        "sha256 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 verified", "Task done: 3 prospects, 2 sites checked, next step queued",
        "Règle: toujours répondre en français, voilà des accents"]


class Vectors(unittest.TestCase):
    def test_vectors(self):
        self.assertGreaterEqual(len(VECTORS), 80)
        for vid, text, forbid, expect in VECTORS:
            out = S.scrub(text, KNOWN)
            sq, dg = squash(out), digits(out)
            for f in forbid:
                if f.startswith("#"):
                    self.assertNotIn(f[1:], dg, f"{vid} leaked digits: {text!r} -> {out!r}")
                else:
                    self.assertNotIn(squash(f), sq, f"{vid} leaked {f}: {text!r} -> {out!r}")
                    self.assertNotIn(f.lower(), out.lower(), f"{vid} leaked {f}: {text!r} -> {out!r}")
            if expect == "uncertain":
                self.assertEqual(out, S.UNCERTAIN, f"{vid} must fail closed: {text!r} -> {out!r}")
            else:
                self.assertNotEqual(out, text, f"{vid} was not touched: {text!r}")
            self.assertEqual(S.scrub(out, KNOWN), out, f"{vid} not idempotent: {out!r}")

    def test_what_must_not_change(self):
        for text in KEEP:
            self.assertEqual(S.scrub(text, KNOWN), text)

    def test_light_mode_keeps_topic_words_and_never_blanks_for_them(self):
        out = S.scrub("The clinic has diabetes patients; income is up. Call Jean Tremblay 613-555-0142", KNOWN)
        self.assertIn("diabetes", out); self.assertNotIn("Tremblay", out); self.assertNotIn("0142", out)

    def test_long_text_and_none_and_errors(self):
        big = "lorem ipsum dolor sit amet. " * 5000 + "Jean Tremblay"
        out = S.scrub(big, KNOWN)
        self.assertNotIn("Tremblay", out); self.assertTrue(out.startswith("lorem"))
        self.assertIsNone(S.scrub(None, KNOWN)); self.assertEqual(S.scrub("", KNOWN), "")
        with mock.patch.object(S, "_normalise", side_effect=RuntimeError("boom")):
            self.assertEqual(S.scrub("Jean Tremblay", KNOWN), S.UNCERTAIN)       # fail closed, never the raw text

    def test_no_database_knowledge_still_removes_contact_data(self):
        out = S.scrub("Jean Tremblay jean@x.example 613-555-0142", S.EMPTY)
        self.assertNotIn("@", out); self.assertNotIn("0142", out)               # names the database does not know cannot be found: stated limit
        self.assertIn("Jean Tremblay", out)

    def test_common_words_are_not_blanked_by_a_lead_called_setter(self):
        k = S.Known(names=["Sam Setter"])
        self.assertEqual(S.scrub("Setter payout (close): setter abc", k), "Setter payout (close): setter abc")
        self.assertNotIn("Sam", S.scrub("paid Sam Setter today", k))


class Known(unittest.TestCase):
    def setUp(self):
        S.reset_cache()

    def test_loads_from_the_database_pages_and_caches(self):
        calls = []
        def get(path):
            calls.append(path)
            t = path.split("?")[0]
            return {"leads": [{"name": "Jean Tremblay", "phone": "613-555-0142", "email": EMAIL}], "setters": [{"name": "Marcus Zzyxwell", "contact": "marcus@setters.example"}]}.get(t, [])
        out = S.scrub_stored("Jean Tremblay and Marcus Zzyxwell wrote", get)
        self.assertNotIn("Tremblay", out); self.assertNotIn("Zzyxwell", out)
        n = len(calls); S.scrub_stored("again", get)
        self.assertEqual(len(calls), n)                                           # cached

    def test_database_failure_keeps_patterns_and_the_previous_list(self):
        def get(path):
            raise RuntimeError("down")
        out = S.scrub_stored("mail a.b@example.com 613-555-0142", get)
        self.assertNotIn("@", out); self.assertNotIn("0142", out)
        good = lambda p: [{"name": "Jean Tremblay"}] if p.startswith("leads") else []
        S.reset_cache(); S.scrub_stored("x", good)
        self.assertNotIn("Tremblay", S.scrub_stored("Jean Tremblay", get))        # previous list still applies while the database is unreachable
        S.reset_cache()


class Board:
    def __init__(self, tasks, leads=()):
        self.tasks, self.leads = tasks, list(leads); self.patches = []; self.inserts = []; self.rpcs = []
    def __call__(self, method, path, body=None, timeout=30, prefer=None, exact=False):
        if path.startswith("/rest/v1/rpc/"):
            name = path.split("/")[-1]; self.rpcs.append((name, body))
            return {"estimate_call_cents": 1}.get(name, 1 if name != "reserve_llm_budget" else "call-1")
        if method == "GET":
            if path.startswith("/rest/v1/system_state"): return [{"kill_switch": False}]
            if path.startswith("/rest/v1/agents"): return [{"slug": "x", "title": "X", "model_tier": "cheap", "role": "r", "metric": "m", "charter": "c"}]
            if path.startswith("/rest/v1/handbook"): return [{"content": "rules"}]
            if path.startswith("/rest/v1/leads"): return list(self.leads)
            if path.startswith("/rest/v1/tasks"): return list(self.tasks)
            return []
        if method == "PATCH":
            self.patches.append((path, body)); return [{"id": 1}] if prefer == "return=representation" else None
        if method == "POST":
            self.inserts.append((path, body)); return None


class Engine(unittest.TestCase):
    """A task still runs and completes, with a scrubbed stored result, while the engine keeps using the raw output for what it needs."""
    def setUp(self):
        S.reset_cache()

    def run_task(self, reply, agent="donna-researcher", leads=({"name": "Jean Tremblay", "phone": "613-555-0142", "email": EMAIL},)):
        b = Board([{"id": "t1", "assigned_agent": agent, "title": "Research HVAC", "detail": "", "venture_id": "v3"}], leads)
        with mock.patch.object(hq, "_request", b), mock.patch.object(E, "_complete", return_value=(reply, 10, 5, 0)), mock.patch.object(E, "_venture_over_budget", return_value=False):
            E.tick_sync()
        return b

    def final(self, b):
        return [p[1] for p in b.patches if "tasks?id=eq.t1" in p[0] and "result" in p[1] and p[1].get("status") in ("done", "blocked")]

    def test_task_completes_with_scrubbed_result(self):
        reply = f"Researched Jean Tremblay.\nEmail: {EMAIL}\nPhone: (613) 555-0142\nhttps://www.linkedin.com/in/jean-tremblay-1234\nFound 3 prospects; see https://acmeplumbing.ca/about\nVERDICT: PASS"
        b = self.run_task(reply)
        done = self.final(b)
        self.assertEqual(len(done), 1); self.assertEqual(done[0]["status"], "done")
        r = done[0]["result"]
        for leak in ("Tremblay", "613", "0142", "@", "jean-tremblay"):
            self.assertNotIn(leak, r)
        self.assertIn("Found 3 prospects", r); self.assertIn("https://acmeplumbing.ca/about", r); self.assertIn("VERDICT: PASS", r)

    def test_engine_still_uses_the_raw_output_for_leads(self):
        reply = "Done.\nLEADS:\n- Cool Air Ottawa | https://coolair.example.ca | 8 trucks | contact: info@coolair.example.ca\n"
        b = self.run_task(reply, leads=())
        self.assertTrue([i for i in b.inserts if "leads" in i[0] and i[1].get("email") == "info@coolair.example.ca"])     # raw text reached the lead capture
        self.assertNotIn("info@coolair.example.ca", self.final(b)[0]["result"])                                             # but not the stored result

    def test_escalation_summary_is_scrubbed_and_keeps_the_title_prefix(self):
        b = self.run_task(f"ESCALATE: owner decision needed. Jean Tremblay {EMAIL} 613-555-0142")
        esc = [i[1] for i in b.inserts if "escalations" in i[0]]
        self.assertTrue(esc and esc[0]["summary"].startswith("Research HVAC: "))      # unblock_task_for() matches on this prefix: it must stay readable
        for leak in ("Tremblay", "@", "0142"):
            self.assertNotIn(leak, esc[0]["summary"])
        self.assertEqual(self.final(b)[0]["status"], "blocked")

    def test_scrubber_failure_stores_the_marker_not_the_raw_text(self):
        with mock.patch.object(S, "_normalise", side_effect=RuntimeError("boom")):
            b = self.run_task("Jean Tremblay 613-555-0142")
        self.assertEqual(self.final(b)[0]["result"], S.UNCERTAIN); self.assertEqual(self.final(b)[0]["status"], "done")

    def test_result_cap_still_applies(self):
        b = self.run_task("word " * 4000)
        self.assertLessEqual(len(self.final(b)[0]["result"]), 8000)

    def test_waiting_for_owner_result_is_scrubbed(self):
        b = self.run_task("QUESTION: Email Jean Tremblay at " + EMAIL + "? | yes | no\n")
        waiting = [p[1]["result"] for p in b.patches if str(p[1].get("result", "")).startswith(E.WAITING_PREFIX)]
        if waiting:
            self.assertNotIn("@", waiting[0]); self.assertNotIn("Tremblay", waiting[0])


if __name__ == "__main__":
    unittest.main()
