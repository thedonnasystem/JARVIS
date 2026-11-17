#!/usr/bin/env python3
"""Writes sqltests/data/phone_fuzz.tsv: a deterministic differential-fuzz corpus for normalize_phone (SQL public.normalize_phone vs hq_consent.normalize_phone).
Column 1 = input in COPY text format (backslash escapes for control characters), column 2 = hq_consent.normalize_phone(input) (\\N = None).
test_hq_consent.py regenerates it and compares (so the file cannot drift from the Python mirror); sqltests/consent_review_fixes_check.sql runs every row through the SQL function.
  python3 scripts/gen_phone_fuzz.py [--check]"""
import os, random, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import hq_consent

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sqltests", "data", "phone_fuzz.tsv")
CCS = ["1", "7", "20", "27", "30", "31", "32", "33", "34", "36", "39", "40", "41", "43", "44", "45", "46", "47", "48", "49", "51", "52", "54", "55", "60", "61", "62", "63", "64", "65", "66", "81", "82",
       "84", "86", "90", "91", "92", "93", "94", "98", "212", "213", "216", "218", "234", "254", "255", "256", "351", "352", "353", "355", "359", "370", "371", "372", "375", "380", "381", "385", "386",
       "420", "421", "880", "961", "962", "963", "964", "965", "966", "967", "968", "970", "971", "972", "973", "974", "977", "995", "999"]
SEPS = [" ", " ", "-", ".", "  ", "\t", " (", ") ", "(", ")", "\u00a0", "\u2009", "\u2028", "\u2029", "\u1680", "\u3000", "\u0085", "\u200b", "\u200e", "\u2010", "\u2212", "\n", "\r", "\f", "\v", "\ufeff"]
ALPHA = list("0123456789") * 3 + list("+()-. \t") + ["x", "ext", "#", "a", "(0)", " (0) ", "٠", "٣", "۷", "０", "１", "＋", "（", "）", ";", ",", "/"] + SEPS


def digits(r, n):
    return "".join(r.choice("0123456789") for _ in range(n))


def structured(r):
    cc = r.choice(CCS)
    lead = r.choice(["+", "+", "+", "00", "", "+ ", "＋"])
    z = r.choice(["", "", "0", "(0)", " (0) ", "00", "( 0 )", "0 "])
    body = digits(r, r.randint(6, 11))
    if cc == "1":
        body = r.choice("23456789") + digits(r, 2) + r.choice("23456789") + digits(r, 6)
    s = lead + cc + r.choice(SEPS) + z + r.choice(SEPS) + body[:3] + r.choice(SEPS) + body[3:]
    if r.random() < 0.15:
        s += r.choice([" x12", " ext. 4", "#5", " extension 7", "\u2028x1", " x"])
    return s


def free(r):
    return "".join(r.choice(ALPHA) for _ in range(r.randint(0, 22)))


def corpus(n=6000, seed=20261115):
    r = random.Random(seed)
    out = []
    for i in range(n):
        out.append(structured(r) if r.random() < 0.6 else free(r))
    return out


def esc(t):
    return t.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r").replace("\f", "\\f").replace("\v", "\\v")


def render():
    lines = []
    for t in corpus():
        e = hq_consent.normalize_phone(t)
        lines.append(esc(t) + "\t" + ("\\N" if e is None else e) + "\n")
    return "".join(lines)


if __name__ == "__main__":
    text = render()
    if "--check" in sys.argv:
        cur = open(OUT, encoding="utf-8", newline="").read()
        sys.exit(0 if cur == text else "phone_fuzz.tsv is out of date: run python3 scripts/gen_phone_fuzz.py")
    open(OUT, "w", encoding="utf-8", newline="").write(text)
    print("wrote", OUT, text.count("\n"), "cases")
