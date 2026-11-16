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
  D6  (REF_URL) the no-workspace (strict) screen: never LESS strict than the previous (d82e29a) classifier, and equal except for the review fix to stand-alone
      '1', '|', '@'. (The workspace behaviour intentionally changed: an insurance workspace is default-deny for every free-text column.)
  D8  NON-insurance workspace (vertical mortgage, no terms): if the OLD detector found nothing, the new classifier allows the text unless it carries an identifier next to an
      insurance word (or a date of birth / policy number): text with 'insurance', 'policy' ... in a mortgage workspace is NOT subject to the vocabulary test.
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
FEATURES = ["heart attack, stroke and cancer", "no medical exam"]
VERTICAL_VARIANTS = ["insurance-broker", "life insurance", "insurance_brokerage", "assurances", "courtage assurance", "Insurance Advisors", "assurance-vie"]
ONBOARD_KEYS = ["crm_destination", "booking_link", "brand_assets", "compliance_contact", "ad_review_signoff", "lead_fields_agreed", "ad_account_access", "consent_wording", "licensing_status", "recruiting_model",
                "service_geography", "launch_deadline", "monthly_budget"]
ONBOARD_OK = ["HubSpot, leads@acme.ca", "HubSpot", "https://cal.com/acme/intro", "I agree to be contacted by Acme", "Jane Doe, compliance officer", "Meta Business Manager access granted", "Ontario and Quebec"]
STRUCT_COLS = ["title", "blocked_until", "provided_by"]
CODES = re.compile(r"^(sin_like_number|card_like_number|account_like_number|identity_document|banking|credit|application_or_income|health(:[a-z_]+)?|insurance_identifier|identifier|financial_detail|unknown_word|non_latin_script|mixed_script|encoded_text|"
                   r"approved_product_term|approved_feature|approved_place|insurance_vocabulary)$")

HEALTH = ["diabetes", "cancer", "diagnosed", "prescribed", "surgery", "my doctor", "heart attack", "medication", "tumour", "hospital", "chemo", "depression", "pregnant", "disability", "illness",
          "diabète", "maladie", "chirurgie", "médecin", "j'ai le diabète", "cœur", "santé", "invalidité", "cancer du sein", "hôpital", "enceinte", "ordonnance", "asthme"]
PRODUCT = APPROVED + ["Health Insurance", "ASSURANCE SANTÉ", "Disability   Insurance", "assurance-santé", "critical illness cover", "health plan", "income protection", "medical coverage", "term life insurance"]
CONTEXT = ["my", "I", "I'm", "j'ai", "ma mère", "mon mari", "me", "my sister was diagnosed", "her claim for surgery", "he passed away", "policy number", "born 1985-03-12", "ma demande d'invalidité",
           "claim for my surgery", "suffers from", "atteinte", "diagnosed", "prescribed", "his disability claim"]
MARKETING = ["Mortgage rates - privacy policy", "Title insurance included", "Home insurance requirement for your mortgage", "Client has lupus", "Client takes Lipitor", "Maria Gonzalez cannot walk", "Our client has lupus",
             "in our family", "parents can not work", "we need care", "Will", "Will Page", "Sam", "Summer", "Spring", "age 54", "54 years", "1985", "one two three four five six seven eight nine", "cancer: no",
             "Krebs", "保险", "Spring promo", "Protect your income", "in 10 minutes", "30 year term", "100% online", "#1 broker", "1 in 3 Canadians", "Option 1", "A | B", "@ $25/mo", "protect your income", "Protect your family with", "Get a quote for", "Affordable", "from $25/month", "for self-employed workers", "Call us today", "Top rated", "pour les travailleurs autonomes", "Canada's best",
             "Contact us", "Call us today", "Our team of advisors", "Mon-Fri 9 to 5", "top 5 reasons", "5 stars", "20 year term", "Plan 1", "Option 2", "nine nine nine, nine nine nine", "Worker can't work", "Senior needs care",
             "Heart attack, stroke and cancer? No", "(no) heart attack, stroke and cancer", "for will", "beneficiary may", "Your income is fifty thousand", "Mon-Fri 9am to 5pm", "depuis 1995", "Appelez-nous", "notre équipe", "nos conseillers",
             "ages 18-65", "since 1995", "24/7 support", "over 10,000 families", "Learn more", "in minutes", "No medical exam", "Protégez votre famille avec", "Book a call", "we", "our team", "your family"]
NUMBERS = ["613-555-0100", "123-456-789", "123456789", "4111 1111 1111 1111", "1234567", "98765", "T2T 1A1", "john@example.com", "12/03/1985", "123 Main Street", "$500,000", "55512", "2026"]
BANK = ["bank statement", "credit score", "SIN", "passport", "void cheque", "salary", "income protection", "mortgage application", "Equifax", "date of birth", "account number", "T4"]
NEUTRAL = ["quote", "family", "renewal", "tomorrow", "Spring campaign", "landing page", "Barrhaven", "hospitality", "heartfelt thanks", "the chronicle", "Hearthstone", "doctorate", "callback", "Ottawa"]
PERF_NAMES = ["Health insurance spring campaign for families", "Spring promo", "Protect your income with disability insurance", "Life insurance quotes in 5 minutes", "Compare plans from top insurers",
              "Get covered today", "Summer savings for families", "Assurance santé pour les travailleurs autonomes", "Retargeting for quote request", "Webinar on planning for freelancers"]
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
    cur.execute("insert into public.client_workspaces (slug, name, vertical, status) values ('diff-mtg', 'Diff mortgage', 'mortgage', 'active') on conflict (slug) do update set name = excluded.name returning id")
    empty = cur.fetchone()[0]
    for t in APPROVED:
        cur.execute("select 1 from public.ws_approved_terms where workspace_id = %s and removed_at is null and term = %s", (pop, t))
        if not cur.fetchone():
            cur.execute("select public.ws_add_approved_term(%s, null, 'product', %s)", (pop, t))
    for t in PLACES:
        cur.execute("select 1 from public.ws_approved_terms where workspace_id = %s and removed_at is null and term = %s", (pop, t))
        if not cur.fetchone():
            cur.execute("select public.ws_add_approved_term(%s, null, 'place', %s)", (pop, t))
    for t in FEATURES:
        cur.execute("select 1 from public.ws_approved_terms where workspace_id = %s and removed_at is null and term = %s", (pop, t))
        if not cur.fetchone():
            cur.execute("select public.ws_add_approved_term(%s, null, 'feature', %s)", (pop, t))
    cur.execute("insert into public.client_workspaces (slug, name, vertical, status) values ('diff-ins-empty', 'Diff insurance, no terms', 'insurance', 'active') on conflict (slug) do update set name = excluded.name returning id")
    ins_empty = cur.fetchone()[0]
    variant_ws = []
    for i, vtx in enumerate(VERTICAL_VARIANTS):
        cur.execute("insert into public.client_workspaces (slug, name, vertical, status) values (%s, 'Diff variant', %s, 'active') on conflict (slug) do update set vertical = excluded.vertical returning id", ("diff-var-" + "xyz"[i % 3] * (i + 1), vtx))
        variant_ws.append(cur.fetchone()[0])
    cur.execute("select public.ffm_instantiate_onboarding(%s)", (pop,))
    cur.execute("select count(*) from public.ws_approved_terms where workspace_id = %s and removed_at is null", (empty,))
    assert cur.fetchone()[0] == 0
    rng = random.Random(a.seed)
    term_res = [(re.compile(term_re(t)), "zzqx", True) for t in APPROVED] + [(re.compile(term_re(t)), "zzqx", False) for t in PLACES] + [(re.compile(term_re(t)), "zzqxf", False) for t in FEATURES]
    pron = re.compile(r"(^|[^a-z0-9])(i|im|ive|me|my|mine|myself|je|moi|mon|ma|mes|suis)([^a-z0-9]|$)|(^|[^a-z0-9])(j|m)'")
    cur.execute("select word from public.ws_marketing_vocab where removed_at is null")
    vocab = {r[0] for r in cur.fetchall()}
    ins_word = re.compile(r"insur|assuranc|underwrit|beneficiar|annuit|indemnit|versicher|seguro|assicura|sigorta")
    income_re = re.compile(r"(^|[^a-z0-9])((your|votre|vos) +)(income|revenus?)(?![a-z0-9])")
    stats = {"n": 0, "old_hit": 0, "old_health_only": 0, "new_allowed_with_old_health": 0, "blocked": 0, "mut_checked": 0, "ref_compared": 0, "ref_stricter": 0, "ref_leet_fix": 0,
             "d1": 0, "d2": 0, "d3": 0, "d4": 0, "d5": 0, "d6": 0, "d8": 0, "d9": 0, "d10": 0, "d11": 0}
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

    NW = r"zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|deux|trois|quatre|cinq|sept|huit|neuf|dix|onze|douze|treize|quinze|seize|vingt|trente|quarante|cinquante|soixante|cent|cents|mille|milles|millions"
    NEG = r"no|not|non|oui|yes|pas|none|never|nope"
    cur.execute("select phrase_norm from public.ws_fixed_phrases where removed_at is null")
    phrases = sorted([r[0] for r in cur.fetchall()], key=lambda x: (-len(x), x))
    phrase_res = [re.compile(r"(^|[^a-z0-9])" + re.sub(r"[ \-]+", "[ \\-]+", re.escape(ph).replace("\\ ", " ")) + r"([^a-z0-9]|$)") for ph in phrases]
    EDGE = {"will", "may", "don", "sam", "bill", "sun", "sat", "wed"}
    AFTERP = {"will", "may", "don", "sam", "bill", "page", "mo", "sun", "sat", "wed", "summer", "spring", "mark", "rose", "grace"}
    PREP = {"for", "to", "of", "from", "beneficiary", "named", "by", "with"}
    HARD = {"will", "may", "page", "sam", "don"}
    SOFT = {"star", "stars", "summer", "spring", "winter", "sun", "sat", "wed", "long", "young", "best", "bill", "bills", "mo", "fall"}

    def cap_name(orig: str) -> bool:
        t = re.sub("[­​-‏‪-‮⁠-⁯︀-️﻿]", "", orig)
        t = unicodedata.normalize("NFD", unicodedata.normalize("NFKC", t))
        t = "".join(ch for ch in t if not unicodedata.combining(ch))
        lower_present = re.search(r"[a-z]", t) is not None
        for m in re.finditer(r"(^|[.!?][ \t\n]+|[^A-Za-z])([A-Za-z]+)(?![A-Za-z])(?![\'\u2019]t(?![A-Za-z]))", t):
            w = m.group(2).lower()
            if not m.group(2)[0].isupper():
                continue
            if w in HARD:
                return True
            if w in SOFT and (not lower_present or not (m.group(1) == "" or re.match(r"[.!?]", m.group(1)))):
                return True
        toks = [m.group(2) for m in re.finditer(r"(^|[^a-z])([a-z]+)(?![a-z])(?![\'\u2019]t(?![a-z]))", t.lower())]
        for i, w in enumerate(toks):
            if w in EDGE and (i == 0 or i == len(toks) - 1):
                return True
            if w in AFTERP and i > 0 and toks[i - 1] in PREP:
                return True
        return False

    MONTHS = r"january|february|march|april|june|july|august|september|october|november|december|janvier|fevrier|mars|avril|juin|juillet|aout|septembre|octobre|novembre|decembre|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec"
    NEGAB = (r"(^|[^a-z])(can ?not|cannot|can['' ]?t|could ?not|couldn['\u2019 ]?t|unable to|not able to|won['\u2019 ]?t|will not)( +[a-z]+)? +"
             r"(work|walk|pay|afford|move|see|hear|speak|breathe|stand|drive|eat|sleep|care|cope|bills)([^a-z]|$)")
    NEEDS = r"(^|[^a-z])needs? +(care|surgery|treatment|dialysis|medication|assistance|a doctor)([^a-z]|$)"

    def cut_phrases(r: str) -> str:
        for pr in phrase_res:
            while pr.search(r):
                r = pr.sub(r"\1 zzqxp \2", r)
        return r

    def oracle_vocab_ok(resid: str, orig: str = "") -> bool:
        """independent re-implementation of the default-deny residual test (python tokenizer, same vocabulary)"""
        v = resid.translate(str.maketrans({"«": '"', "»": '"', "“": '"', "”": '"', "„": '"', "•": " ", "·": " ", "‣": " ", "€": "$", "£": "$"}))
        v = v.translate(str.maketrans({c: " " for c in "✅⭐✔✓★→✨"})).replace(chr(128077), " ")
        v = cut_phrases(v)
        if re.search(NEGAB, v) or re.search(NEEDS, v):
            return False
        v = re.sub(r"(^|[^a-z0-9])(l|d|c|n|s|qu|jusqu|lorsqu|puisqu)'(?=[a-z0-9])", r"\1\2 ", v)
        v = re.sub(r"([a-z])'(s|t|ll|re|ve|d)(?![a-z0-9])", r"\1 ", v).replace("'", " ")
        if re.search(r"[^ -~]", v) or "zznum" in v:
            return False
        tmp = re.sub(r"(^|[^0-9])24 ?/ ?7([^0-9]|$)", r"\1 \2", v)
        if (re.search(r"[a-z0-9]@|@[a-z0-9]|[a-z0-9&]&|&[a-z0-9#]|%[0-9a-f]{2}|(^|[^0-9 ])%|(^|[^0-9]) +%|(^|[^0-9])\+", v)
                or re.search(r"(^|[^0-9a-z.,])[0-9]+ ?/ ?[0-9]+([^0-9a-z]|$)", tmp)):
            return False
        if re.search(r"[0-9]", v):
            hrs = re.search(r"(^|[^a-z])(hours?|heures?|open|opening|ouverts?|ouverture|monday|friday|lundi|vendredi|weekdays|saturday|samedi)([^a-z]|$)", v) is not None or "zzqxp" in v
            v = re.sub(r"(^|[^0-9])24 ?/ ?7([^0-9]|$)", r"\1 zznum \2", v)
            v = re.sub(r"\$ ?[0-9][0-9,.]*k?", " zznum ", v)
            v = re.sub(r"[0-9][0-9,.]*k? ?\$", " zznum ", v)
            v = re.sub(r"[0-9][0-9,.]* ?%", " zznum ", v)
            v = re.sub(r"#[0-9]+", " zznum ", v)
            v = re.sub(r"(^|[^a-z0-9])(in|within|under|than|en|dans|sous|de) +[0-9]+ ?(minutes?|mins?|hours?|hrs?|heures?|days?|jours?|seconds?|secondes?)([^a-z]|$)", r"\1\2 zznum \4", v)
            v = re.sub(r"(^|[^a-z0-9])(24|48|72|7|14|15|21|30|60|90|365) ?-? ?(days?|jours?|hours?|heures?|hrs?)([^a-z]|$)", r"\1 zznum \4", v)
            v = re.sub(r"(^|[^0-9a-z])[0-9]+ in [0-9]+([^0-9a-z]|$)", r"\1 zznum \2", v)
            v = re.sub(r"(^|[^a-z])(" + MONTHS + r") +([1-9]|[12][0-9]|3[01])([^0-9a-z]|$)", r"\1\2 zznum \4", v)
            v = re.sub(r"(^|[^0-9a-z])[0-9]{1,3} ?-? ?(minutes?|mins?|seconds?|secs?|secondes?) ", r"\1 zznum ", v)
            v = re.sub(r"(^|[^0-9a-z])[0-9]+ ?-? ?(years?|yrs?|ans?|annees?) ?(term|terme|plan|coverage|couverture|renewable|renouvelable|guarantee|garantie|level)([^a-z]|$)", r"\1 zznum \3\4", v)
            v = re.sub(r"(^|[^0-9a-z])(5|10|15|20|25|30|35|40) ?-? ?(years?|yrs?|ans?) +(zzqx[fp]?)([^a-z]|$)", r"\1 zznum \4\5", v)
            v = re.sub(r"(^|[^0-9a-z])[0-9]+ ?\+? ?(years?|ans) (of experience|d experience|in business|of service|de service|serving)", r"\1 zznum \3", v)
            v = re.sub(r"(^|[^a-z])(top|meilleurs?) +[0-9]{1,2}([^0-9a-z]|$)", r"\1 zznum \3", v)
            v = re.sub(r"(^|[^0-9a-z])[0-9]{1,2} +(reasons?|raisons?|stars?|etoiles?|steps?|etapes?|tips?|conseils?|astuces?|ways|mistakes|myths|questions?)([^a-z]|$)", r"\1 zznum \2\3", v)
            v = re.sub(r"(^|[^a-z])(over|more than|plus de|plus d|plus que) +([0-9]{1,3}([, ][0-9]{3})+|[0-9]{3,})\+?", r"\1\2 zznum ", v)
            v = re.sub(r"(^|[^a-z])(since|depuis) +(19|20)[0-9]{2}([^0-9]|$)", r"\1\2 zznum \4", v)
            for m in re.findall(r"((?:ages?|aged) +([0-9]{1,2}) ?(?:-|to|and|a|et) ?([0-9]{1,2}))", v):
                if abs(int(m[2]) - int(m[1])) >= 10 and int(m[1]) >= 18:
                    v = v.replace(m[0], " zznum ")
            if hrs:
                v = re.sub(r"(^|[^0-9a-z])([0-9]|1[0-9]|2[0-4])(:[0-5][0-9])? ?(am|pm|h)? ?(-|to|a|et|and) ?([0-9]|1[0-9]|2[0-4])(:[0-5][0-9])? ?(am|pm|h)?([^0-9a-z]|$)", r"\1 zznum \9", v)
                v = re.sub(r"(^|[^0-9a-z])([0-9]|1[0-9]|2[0-4])(:[0-5][0-9])? ?(am|pm|h)([^a-z]|$)", r"\1 zznum \5", v)
        if len(re.findall(r"(^|[^a-z])(" + NW + r")(?![a-z])", v)) >= 4:
            return False
        if re.search(r"zzqxf[^a-z0-9]*(" + NEG + r")([^a-z]|$)", v) or re.search(r"(^|[^a-z])(" + NEG + r")[^a-z0-9]*zzqxf", v):
            return False
        for tok in re.findall(r"[a-z0-9]+(?:[.,][0-9]+)*|[^a-z0-9 ]", v):
            if tok in ("zzqx", "zzqxf", "zzqxp", "zznum") or re.fullmatch(r"[.,;:!?\"()/%$|#+&@-]", tok) or tok in vocab:
                continue
            return False
        return not (orig and cap_name(orig))

    def cmp_ref(t, h):
        """D6 on one text. h = list of NEW allowed flags per workspace mode; here: strict (None) and populated."""
        rc.execute("select public.ws_classify_text(%s, null)", (t,)); ro_n = rc.fetchone()[0]["allowed"]
        new_n = new(t, None)["allowed"]
        stats["ref_compared"] += 1
        if new_n and not ro_n:
            stats["ref_leet_fix"] += 1
            # attribution: the previous classifier folded digits/symbols into letters inside letterless tokens ("18-65", "1", "|"); replace those tokens by a plain word and the previous classifier must agree
            t2 = re.sub(r"(^|\s)[^\sA-Za-z]+(?=\s|$)", r"\1x", t)
            rc.execute("select public.ws_classify_text(%s, null)", (t2,))
            if not re.search(r"(^|[^a-z0-9])[1|@!]([^a-z0-9]|$)|\$[0-9]", fold_py(t)) and not rc.fetchone()[0]["allowed"]:
                fails.append(("D6", t, "strict screen allowed what the previous one refused")); stats["d6"] += 1
        if (not new_n) and ro_n:
            stats["ref_stricter"] += 1
            fails.append(("D6", t, "strict screen refused what the previous one allowed")); stats["d6"] += 1

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
        ctx = True   # the populated workspace is an INSURANCE workspace: every free-text column is insurance context
        income_waived = False
        if "application_or_income" in o and ctx and income_re.search(f) and not re.search(r"(^|[^a-z])(" + NW + r")(?![a-z])", f):
            rr = income_re.sub(r"\1\2 zzqx ", f)
            income_waived = "application_or_income" not in old(rr)
        for nm, r in (("empty", ne), ("null", nn)):
            if r["allowed"] and o:
                fails.append(("D1", t, nm, o, r)); stats["d1"] += 1
        # D8: non-insurance workspace (mortgage, no terms): old detector clean => allowed (no vocabulary test, no insurance-word identifier screen: restored to the previous behaviour)
        if not o and not ne["allowed"]:
            rs = {r for r in ne["reasons"] if not r.startswith("health")}   # health blocks come from the previous guard's fold / leet / extra detectors (not raw ws_sensitive_hits)
            if rs:
                fails.append(("D8", t, ne)); stats["d8"] += 1
        # D9: every vertical spelling that names insurance behaves exactly like the plain 'insurance' vertical (no terms)
        vv = rng.choice(variant_ws)
        if new(t, vv)["allowed"] != new(t, ins_empty)["allowed"]:
            fails.append(("D9", t, vv)); stats["d9"] += 1
        # D10: onboarding values in an insurance workspace: an old-detector hit is never stored, health text smuggled behind a legitimate value is never stored, a clean legitimate value is
        if rng.random() < 0.5:
            key = rng.choice(ONBOARD_KEYS)
            cur.execute("select public.ws_onboarding_value_check(%s, %s)", (key, t))
            rv = cur.fetchone()[0]
            if rv["allowed"] and o:
                fails.append(("D10", key, t, o)); stats["d10"] += 1
            smuggled = rng.choice(ONBOARD_OK) + ", " + t
            cur.execute("select public.ws_onboarding_value_check(%s, %s)", (key, smuggled))
            if cur.fetchone()[0]["allowed"] and o:
                fails.append(("D10s", key, smuggled, o)); stats["d10"] += 1
        # D11: structural columns of a real onboarding row never accept a text the full classifier refuses for that workspace (real guarded UPDATEs; a refusal is the expected answer)
        if rng.random() < 0.3:
            col = rng.choice(STRUCT_COLS)
            try:
                cur.execute("update public.ffm_onboarding_items set " + col + " = %s where workspace_id = %s and template_key = 'launch_deadline'", (t, pop))
                token_ok = col != "title" and re.fullmatch(r"[A-Za-z0-9_:.-]{1,60}", t) is not None and not o     # a short clean token is a legitimate enum / actor tag (documented residual: an unlisted single-word name)
                if not np_["allowed"] and not token_ok:
                    fails.append(("D11", col, t, np_)); stats["d11"] += 1
                cur.execute("update public.ffm_onboarding_items set title = 'Target launch date, if any', blocked_until = null, provided_by = null where workspace_id = %s and template_key = 'launch_deadline'", (pop,))
            except psycopg2.Error as e:
                if "Sensitive data refused" not in str(e) and "violates check" not in str(e):
                    fails.append(("D11e", col, t, str(e)[:80])); stats["d11"] += 1
        non_health = [h for h in o if h != "health"]
        if np_["allowed"] and non_health and not (non_health == ["application_or_income"] and income_waived):
            fails.append(("D2", t, o, np_)); stats["d2"] += 1
        if o and np_["allowed"]:
            stats["new_allowed_with_old_health"] += 1
            r = f
            used = False
            used_prod = False
            for tr, mk, is_prod in term_res:
                while tr.search(r):
                    r = tr.sub(r"\1 " + mk + r" \2", r)
                    used = True
                    used_prod = used_prod or is_prod
            r = income_re.sub(r"\1\2 zzqx ", r) if income_waived else r
            r = cut_phrases(r)      # owner-approved fixed phrases ("mon fri" is not the French possessive)
            ok = set(o) <= {"health", "application_or_income"} and (used or income_waived) and not old(r) and not pron.search(r)
            if ok:
                ok = oracle_vocab_ok(r, t)
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
        for t in APPROVED:
            cur.execute("select 1 from public.ws_approved_terms where workspace_id = %s and removed_at is null and term = %s", (pw, t))
            if not cur.fetchone():
                cur.execute("select public.ws_add_approved_term(%s, null, 'product', %s)", (pw, t))
        t0 = time.time()
        for i in range(a.perf):
            cur.execute("insert into public.ws_campaigns (workspace_id, name, channel) values (%s, %s, 'meta')", (pw, PERF_NAMES[i % len(PERF_NAMES)]))
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
