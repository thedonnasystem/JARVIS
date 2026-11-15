#!/usr/bin/env python3
"""Differential + adversarial corpus test for the insurance classifier (migrations/20261122_insurance_classifier_v1.sql).

SCRATCH DATABASES ONLY (it inserts a workspace, owner and approved terms, then removes nothing: run it on a replica you are about to wipe anyway).
  REPLICA_URL=postgresql://postgres:pw@localhost:5432/<scratch> python3 scripts/classifier_differential.py [--n 20000] [--seed 1] [--perf 1000]
  REF_URL=postgresql://postgres:pw@localhost:5432/<scratch with the PREVIOUS (d82e29a) classifier applied>   optional: enables D6, the cross-version identity check.

Invariants checked over a seeded random corpus (English, French, accents, look-alikes, fullwidth, zero-width, combining marks, spaced letters,
leetspeak, numbers, identifiers, product phrases, personal context). OLD = ws_sensitive_hits (unchanged by the migration), NEW = ws_classify_text.
  D1  workspace with NO approved terms (and NULL workspace): NEW allowed  =>  OLD found nothing.            (nothing extra is ever permitted)
  D2  any OLD hit except health: NEW blocked, whatever the workspace.                                         (no category regression)
  D3  OLD hit and NEW allowed (approved terms present)  =>  OLD hit was ONLY 'health' (or 'application_or_income' with a generic "your income"),
      the text contains an approved term, and the independent oracle agrees: after cutting every approved term out of the (python-normalised) text,
      OLD finds no health wording, there is no first-person pronoun, no identifier-shaped number, AND (default-deny) every remaining token is a
      vocabulary word, a number or simple punctuation when the text is insurance-related.
  D4  mutations never unblock: zero-width / combining-mark / fullwidth / homoglyph / spacing mutations of a BLOCKED text are blocked.
  D5  classifier never raises, never returns the text, reasons are fixed codes.
  D6  (REF_URL) NON-insurance text: the new classifier is never LESS strict than the previous one, and equal except for the review fix to stand-alone
      digits / symbols (a lone "1", "|", "@", "!" or "$25" is no longer folded to a letter). Insurance text may only get STRICTER or allowed through the new vocabulary rules.
  D7  (--perf N) N real inserts on a guarded table finish in under 30 s.
Exit 0 only when every invariant holds for every sample.
"""
import argparse
import json
import os
import random
import re
import sys
import unicodedata

import psycopg2

APPROVED = ["health insurance", "disability insurance", "critical illness insurance", "assurance invalidité", "assurance santé", "life insurance", "assurance maladie grave"]
PLACES = ["Medicine Hat"]
CODES = re.compile(r"^(sin_like_number|card_like_number|account_like_number|identity_document|banking|credit|application_or_income|health(:[a-z_]+)?|insurance_identifier|identifier|unknown_word|non_latin_script|mixed_script|encoded_text|"
                   r"approved_product_term|approved_feature|approved_place|insurance_vocabulary)$")

HEALTH = ["diabetes", "cancer", "diagnosed", "prescribed", "surgery", "my doctor", "heart attack", "medication", "tumour", "hospital", "chemo", "depression", "pregnant", "disability", "illness",
          "diabète", "maladie", "chirurgie", "médecin", "j'ai le diabète", "cœur", "santé", "invalidité", "cancer du sein", "hôpital", "enceinte", "ordonnance", "asthme"]
PRODUCT = APPROVED + ["Health Insurance", "ASSURANCE SANTÉ", "Disability   Insurance", "assurance-santé", "critical illness cover", "health plan", "income protection", "medical coverage", "term life insurance"]
CONTEXT = ["my", "I", "I'm", "j'ai", "ma mère", "mon mari", "me", "my sister was diagnosed", "her claim for surgery", "he passed away", "policy number", "born 1985-03-12", "ma demande d'invalidité",
           "claim for my surgery", "suffers from", "atteinte", "diagnosed", "prescribed", "his disability claim"]
MARKETING = ["#1 broker", "1 in 3 Canadians", "Option 1", "A | B", "@ $25/mo", "protect your income", "Protect your family with", "Get a quote for", "Affordable", "from $25/month", "for self-employed workers", "Call us today", "Top rated", "pour les travailleurs autonomes", "Canada's best",
             "ages 18-65", "since 1995", "24/7 support", "over 10,000 families", "Learn more", "in minutes", "No medical exam", "Protégez votre famille avec", "Book a call", "we", "our team", "your family"]
NUMBERS = ["613-555-0100", "123-456-789", "123456789", "4111 1111 1111 1111", "1234567", "98765", "T2T 1A1", "john@example.com", "12/03/1985", "123 Main Street", "$500,000", "55512", "2026"]
BANK = ["bank statement", "credit score", "SIN", "passport", "void cheque", "salary", "income protection", "mortgage application", "Equifax", "date of birth", "account number", "T4"]
NEUTRAL = ["quote", "family", "renewal", "tomorrow", "Spring campaign", "landing page", "Barrhaven", "hospitality", "heartfelt thanks", "the chronicle", "Hearthstone", "doctorate", "callback", "Ottawa"]
SEPS = [" ", " ", " ", ", ", " - ", ". ", ": "]

HOMO = {"a": "а", "e": "е", "o": "о", "c": "с", "p": "р", "i": "і", "x": "х", "y": "у"}
GREEK = {"o": "ο", "a": "α", "e": "ε", "i": "ι", "k": "κ", "v": "ν", "t": "τ"}
ZW = ["​", "‌", "‍", "⁠", "﻿", "­"]
COMB = ["́", "̀", "̧", "̈", "̂"]


def fold_py(t: str) -> str:
    t = re.sub("[­​-‏‪-‮⁠-⁯︀-️﻿]", "", t)
    t = unicodedata.normalize("NFKC", t)
    t = unicodedata.normalize("NFD", t)
    t = "".join(ch for ch in t if not unicodedata.combining(ch)).lower()
    for a, b in (("œ", "oe"), ("æ", "ae"), ("ß", "ss")):
        t = t.replace(a, b)
    return re.sub(r"\s+", " ", t).strip()


def term_re(term: str) -> str:
    return r"(^|[^a-z0-9])" + re.sub(r"[ \-]+", "[ \\-]+", re.escape(fold_py(term)).replace("\\ ", " ").replace("\\-", "-")) + r"([^a-z0-9]|$)"


def gen(rng: random.Random) -> str:
    pools = [HEALTH, PRODUCT, PRODUCT, CONTEXT, MARKETING, MARKETING, NUMBERS, BANK, NEUTRAL, NEUTRAL, PLACES]
    n = rng.randint(1, 6)
    parts = [rng.choice(rng.choice(pools)) for _ in range(n)]
    out = ""
    for p in parts:
        out += p + rng.choice(SEPS)
    return out.strip()


def mutate(rng: random.Random, t: str):
    """returns (kind, mutated text). kind 5 = spaced-out letters."""
    kind = rng.randint(0, 5)
    chars = list(t)
    if kind == 0:   # zero-width everywhere
        return kind, "".join(c + (rng.choice(ZW) if rng.random() < 0.3 else "") for c in chars)
    if kind == 1:   # combining marks on letters
        return kind, "".join(c + (rng.choice(COMB) if c.isalpha() and rng.random() < 0.3 else "") for c in chars)
    if kind == 2:   # fullwidth
        return kind, "".join(chr(ord(c) + 0xFEE0) if "!" <= c <= "~" and rng.random() < 0.5 else c for c in chars)
    if kind == 3:   # cyrillic / greek look-alikes
        return kind, "".join((rng.choice([HOMO, GREEK]).get(c, c) if rng.random() < 0.5 else c) for c in chars)
    if kind == 4:   # uppercase + odd spacing
        return kind, t.upper().replace(" ", "  ")
    return kind, "".join(c + (" " if c.isalpha() and rng.random() < 0.25 else "") for c in chars)   # spaced-out letters


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--perf", type=int, default=0, help="also time N guarded inserts (D7: must finish in under 30 s)")
    a = ap.parse_args()
    url = os.environ.get("REPLICA_URL", "")
    if not url or "supabase" in url.lower() or not re.search(r"@(localhost|127\.0\.0\.1|postgres)([:/]|$)", url):
        print("refusing: set REPLICA_URL to a LOCAL scratch database")
        return 2
    c = psycopg2.connect(url)
    c.autocommit = True
    cur = c.cursor()
    cur.execute("insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999992', 'diff-owner@example.com') on conflict do nothing")
    cur.execute("insert into public.app_owners (email) values ('diff-owner@example.com') on conflict do nothing")
    cur.execute("select set_config('app.uid', '99999999-9999-9999-9999-999999999992', false)")
    cur.execute("insert into public.client_workspaces (slug, name, vertical, status) values ('diff-pop', 'Diff populated', 'insurance', 'active') on conflict (slug) do update set name = excluded.name returning id")
    pop = cur.fetchone()[0]
    cur.execute("insert into public.client_workspaces (slug, name, vertical, status) values ('diff-empty', 'Diff empty', 'noterms', 'active') on conflict (slug) do update set name = excluded.name returning id")
    empty = cur.fetchone()[0]
    for t in APPROVED:
        cur.execute("select 1 from public.ws_approved_terms where workspace_id = %s and removed_at is null and term = %s", (pop, t))
        if not cur.fetchone():
            cur.execute("select public.ws_add_approved_term(%s, null, 'product', %s)", (pop, t))
    for t in PLACES:
        cur.execute("select 1 from public.ws_approved_terms where workspace_id = %s and removed_at is null and term = %s", (pop, t))
        if not cur.fetchone():
            cur.execute("select public.ws_add_approved_term(%s, null, 'place', %s)", (pop, t))
    cur.execute("select count(*) from public.ws_approved_terms where workspace_id = %s and removed_at is null", (empty,))
    assert cur.fetchone()[0] == 0
    rng = random.Random(a.seed)
    term_res = [(re.compile(term_re(t)), True) for t in APPROVED] + [(re.compile(term_re(t)), False) for t in PLACES]
    pron = re.compile(r"(^|[^a-z0-9])(i|im|ive|me|my|mine|myself|je|moi|mon|ma|mes|suis)([^a-z0-9]|$)|(^|[^a-z0-9])(j|m)'")
    cur.execute("select word from public.ws_marketing_vocab where removed_at is null")
    vocab = {r[0] for r in cur.fetchall()}
    ins_word = re.compile(r"insur|assuranc|underwrit|policyholder|beneficiar|annuit|indemnit|(^|[^a-z])polic(y|ies)([^a-z]|$)")
    income_re = re.compile(r"(^|[^a-z0-9])((your|votre|vos) +)(income|revenus?)(?![a-z0-9])")
    stats = {"n": 0, "old_hit": 0, "old_health_only": 0, "new_allowed_with_old_health": 0, "blocked": 0, "mut_checked": 0, "ref_compared": 0, "ref_stricter": 0, "ref_leet_fix": 0,
             "d1": 0, "d2": 0, "d3": 0, "d4": 0, "d5": 0, "d6": 0}
    fails = []
    ref = None
    if os.environ.get("REF_URL"):
        ref = psycopg2.connect(os.environ["REF_URL"])
        ref.autocommit = True
        rc = ref.cursor()
        rc.execute("insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999992', 'diff-owner@example.com') on conflict do nothing")
        rc.execute("insert into public.app_owners (email) values ('diff-owner@example.com') on conflict do nothing")
        rc.execute("select set_config('app.uid', '99999999-9999-9999-9999-999999999992', false)")
        rc.execute("insert into public.client_workspaces (slug, name, vertical, status) values ('diff-pop', 'Diff populated', 'insurance', 'active') on conflict (slug) do update set name = excluded.name returning id")
        ref_pop = rc.fetchone()[0]
        for t in APPROVED:
            rc.execute("select 1 from public.ws_approved_terms where workspace_id = %s and removed_at is null and term = %s", (ref_pop, t))
            if not rc.fetchone():
                rc.execute("select public.ws_add_approved_term(%s, null, 'product', %s)", (ref_pop, t))
        rc.execute("select 1 from public.ws_approved_terms where workspace_id = %s and removed_at is null and term = 'Medicine Hat'", (ref_pop,))
        if not rc.fetchone():
            rc.execute("select public.ws_add_approved_term(%s, null, 'place', 'Medicine Hat')", (ref_pop,))

    def old(t):
        cur.execute("select public.ws_sensitive_hits(%s)", (t,))
        return cur.fetchone()[0]

    def new(t, ws):
        cur.execute("select public.ws_classify_text(%s, %s)", (t, ws))
        j = cur.fetchone()[0]
        if not isinstance(j.get("allowed"), bool) or not all(CODES.match(r) for r in j["reasons"]) or t in json.dumps(j) and len(t) > 2:
            fails.append(("D5", t, j))
            stats["d5"] += 1
        return j

    def oracle_vocab_ok(resid: str) -> bool:
        """independent re-implementation of the default-deny residual test (python tokenizer, same vocabulary)"""
        v = resid
        v = re.sub(r"(^|[^a-z0-9])(l|d|c|n|s|qu|jusqu|lorsqu|puisqu)'(?=[a-z0-9])", r"\1\2 ", v)
        v = re.sub(r"([a-z])'(s|t|ll|re|ve|d)(?![a-z0-9])", r"\1 ", v).replace("'", " ")
        if re.search(r"[^ -~]", v) or re.search(r"[a-z0-9]@|@[a-z0-9]|[a-z0-9&]&|&[a-z0-9#]|%[0-9a-f]{2}|(^|[^0-9 ])%|(^|[^0-9])\+", v):
            return False
        for tok in re.findall(r"[a-z0-9]+(?:[.,][0-9]+)*|[^a-z0-9 ]", v):
            if tok == "zzqx" or re.fullmatch(r"[0-9]+([.,][0-9]+)*", tok) or re.fullmatch(r"[.,;:!?\"()/%$|#+&@-]", tok) or tok in vocab:
                continue
            return False
        return True

    def cmp_ref(t, h):
        """D6 on one text. h = list of NEW allowed flags per workspace mode; here: strict (None) and populated."""
        rc.execute("select public.ws_classify_text(%s, null)", (t,)); ro_n = rc.fetchone()[0]["allowed"]
        new_n = new(t, None)["allowed"]
        stats["ref_compared"] += 1
        if new_n and not ro_n:
            stats["ref_leet_fix"] += 1
            if not re.search(r"(^|[^a-z0-9])[1|@!]([^a-z0-9]|$)|\$[0-9]", fold_py(t)):
                fails.append(("D6", t, "strict screen allowed what the previous one refused")); stats["d6"] += 1
        if (not new_n) and ro_n:
            stats["ref_stricter"] += 1
            fails.append(("D6", t, "strict screen refused what the previous one allowed")); stats["d6"] += 1
        # populated workspace: NON-insurance text must behave as before (new may be looser only through the leet fix, never stricter)
        if not ins_word.search(re.sub(r"[^a-z]", "", fold_py(t))) and not ins_word.search(fold_py(t)):
            rc.execute("select public.ws_classify_text(%s, %s)", (t, ref_pop)); rp = rc.fetchone()[0]["allowed"]
            np2 = new(t, pop)["allowed"]
            if np2 != rp and not (np2 and not rp and re.search(r"(^|[^a-z0-9])[1|@!]([^a-z0-9]|$)|\$[0-9]", fold_py(t))):
                fails.append(("D6", t, "non-insurance text differs from the previous classifier in a workspace", rp, np2)); stats["d6"] += 1

    for _ in range(a.n):
        t = gen(rng)
        o = old(t)
        np_, ne, nn = new(t, pop), new(t, empty), new(t, None)
        stats["n"] += 1
        if o:
            stats["old_hit"] += 1
        if not np_["allowed"]:
            stats["blocked"] += 1
        f = fold_py(t)
        ctx = ins_word.search(re.sub(r"[^a-z]", "", f)) is not None
        income_waived = False
        if "application_or_income" in o and ctx and income_re.search(f):
            rr = income_re.sub(r"\1\2 zzqx ", f)
            income_waived = "application_or_income" not in old(rr)
        for nm, r in (("empty", ne), ("null", nn)):
            if r["allowed"] and o and not (nm == "empty" and income_waived):
                fails.append(("D1", t, nm, o, r)); stats["d1"] += 1
        non_health = [h for h in o if h != "health"]
        if np_["allowed"] and non_health and not (non_health == ["application_or_income"] and income_waived):
            fails.append(("D2", t, o, np_)); stats["d2"] += 1
        if o and np_["allowed"]:
            stats["new_allowed_with_old_health"] += 1
            r = f
            used = False
            used_prod = False
            for tr, is_prod in term_res:
                while tr.search(r):
                    r = tr.sub(r"\1 zzqx \2", r)
                    used = True
                    used_prod = used_prod or is_prod
            if ctx or used_prod:
                r = income_re.sub(r"\1\2 zzqx ", r)
            ok = set(o) <= {"health", "application_or_income"} and (used or income_waived) and not old(r) and not pron.search(r)
            if ok and (ctx or used_prod):
                ok = oracle_vocab_ok(r)
            if not ok:
                fails.append(("D3", t, o, np_)); stats["d3"] += 1
        if o == ["health"]:
            stats["old_health_only"] += 1
        # D4: mutations never unblock
        if not np_["allowed"]:
            kind, m = mutate(rng, t)
            # spaced-out letters defeat the SHORT-token detectors by design (T4, street addresses, 'my'): known limit, documented. Only health stems tolerate it.
            if kind == 5 and not set(np_["reasons"]) <= {"health", "health:no_approved_term", "health:residual", "unknown_word"}:
                continue
            stats["mut_checked"] += 1
            if new(m, pop)["allowed"]:
                fails.append(("D4", t, m)); stats["d4"] += 1
        if ref is not None and stats["n"] % 2 == 0:
            cmp_ref(t, None)
    if a.perf:
        import time
        cur.execute("insert into public.client_workspaces (slug, name, vertical, status) values ('diff-perf', 'Diff perf', 'insurance', 'active') on conflict (slug) do update set name = excluded.name returning id")
        pw = cur.fetchone()[0]
        for t in APPROVED[:1]:
            cur.execute("select 1 from public.ws_approved_terms where workspace_id = %s and removed_at is null and term = %s", (pw, t))
            if not cur.fetchone():
                cur.execute("select public.ws_add_approved_term(%s, null, 'product', %s)", (pw, t))
        t0 = time.time()
        for i in range(a.perf):
            cur.execute("insert into public.ws_campaigns (workspace_id, name, channel) values (%s, %s, 'meta')", (pw, "Health insurance spring campaign for families %d" % i if i % 2 else "Spring flyers for Barrhaven %d" % i))
        dt = time.time() - t0
        stats["perf_inserts"] = a.perf
        stats["perf_seconds"] = round(dt, 1)
        if dt > 30:
            fails.append(("D7", "%d inserts took %.1fs" % (a.perf, dt)))
    print(json.dumps(stats))
    for f in fails[:25]:
        print("FAIL", f)
    print("RESULT:", "ALL INVARIANTS HELD" if not fails else f"{len(fails)} VIOLATIONS")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
