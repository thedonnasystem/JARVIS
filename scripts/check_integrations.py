#!/usr/bin/env python3
"""Which external connections are present or missing (FENDEZY GROUP Phase 1, M7; inventory in ops/CONNECT_SESSION_CHECKLIST.md).

It looks ONLY at whether each environment variable is set and non-empty. It never prints, logs, hashes or sends a value, and makes no network call.
Pure stdlib, read-only.

  python3 scripts/check_integrations.py                 every integration
  python3 scripts/check_integrations.py --office donna  only what that office uses
  python3 scripts/check_integrations.py --json          machine-readable (names and states only)
  python3 scripts/check_integrations.py --strict        exit 1 when a CORE connection is not present

States: present (every required name set), partial (some set), missing (none set), manual (no credential by design, e.g. RBC),
        not-built (no code uses it yet: nothing to connect), auto (set by the platform, e.g. Railway).
"""
import argparse
import json
import os
import sys

ALL = ("b2b-records", "donna", "the-trap", "wolf-squad", "pimp-ai", "monopoly", "ff-marketing", "fruition-factory")

# key, name, required env names, optional env names, offices, code exists, risk tier, core (needed before any office runs)
INTEGRATIONS = [
    ("telegram", "Telegram bot (owner commands, approvals)", ["TELEGRAM_BOT_TOKEN", "JARVIS_OWNER_ID"], [], ALL, True, "red", True),
    ("supabase", "Supabase HQ database (service path)", ["HQ_SUPABASE_URL", "HQ_SUPABASE_SERVICE_KEY"], [], ALL, True, "red", True),
    ("scoped_tokens", "Supabase scoped office tokens (M1)", ["FZ_SCOPED_TOKENS"], ["FZ_GATEWAY_APIKEY"], ALL, True, "red", False),
    ("anthropic", "Anthropic API (Jarvis LLM; daily AI cap enforced in the database)", ["ANTHROPIC_API_KEY"], ["CLAUDE_MODEL", "HQ_MODEL_CHEAP", "HQ_MODEL_STANDARD", "HQ_MODEL_STRONG"], ALL, True, "yellow", True),
    ("railway", "Railway hosting (deploy metadata, set by Railway)", [], ["RAILWAY_DEPLOYMENT_ID", "RAILWAY_GIT_COMMIT_SHA"], ALL, True, "red", False),
    ("vault", "Bitwarden Secrets Manager (OAuth / API tokens)", ["BW_ACCESS_TOKEN", "BW_ORGANIZATION_ID", "BW_PROJECT_ID"], [], ALL, True, "red", False),
    ("llm_free", "Free / backup LLM providers", [], ["OPENROUTER_API_KEY", "GROQ_API_KEY", "CEREBRAS_API_KEY", "NVIDIA_API_KEY", "GITHUB_MODELS_TOKEN"], ("fruition-factory",), True, "yellow", False),
    ("openai_voice", "OpenAI transcription (voice notes)", ["OPENAI_API_KEY"], ["TRANSCRIBE_MODEL"], ALL, True, "yellow", False),
    ("resend", "Resend email sending (CASL gate + suppression enforced)", ["RESEND_API_KEY", "MAIL_FROM"], ["MAIL_REPLY_TO"], ("donna", "wolf-squad", "monopoly", "ff-marketing"), True, "red", False),
    ("google", "Google OAuth app (Calendar, YouTube uploads)", ["GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET"], [], ("donna", "wolf-squad", "monopoly", "ff-marketing", "b2b-records", "pimp-ai"), True, "yellow", False),
    ("meta", "Meta app (Facebook Pages + Instagram posting)", ["META_APP_ID", "META_APP_SECRET"], ["HANDS_OAUTH_REDIRECT"], ("ff-marketing", "donna", "the-trap", "pimp-ai", "b2b-records"), True, "red", False),
    ("tiktok", "TikTok app (video posting)", ["TIKTOK_CLIENT_KEY", "TIKTOK_CLIENT_SECRET"], ["HANDS_OAUTH_REDIRECT"], ("ff-marketing", "the-trap", "pimp-ai", "b2b-records"), True, "red", False),
    ("linkedin", "LinkedIn app (posting)", ["LINKEDIN_CLIENT_ID", "LINKEDIN_CLIENT_SECRET"], ["HANDS_OAUTH_REDIRECT"], ("ff-marketing", "wolf-squad"), True, "red", False),
    ("x", "X / Twitter app (posting)", ["X_CLIENT_ID"], ["X_CLIENT_SECRET", "HANDS_OAUTH_REDIRECT"], ("ff-marketing", "pimp-ai"), True, "red", False),
    ("automation", "n8n / Make webhooks (Donna automations)", [], ["N8N_BASE_URL", "N8N_API_KEY", "MAKE_WEBHOOK_URL"], ("donna",), True, "yellow", False),
    ("wholesale_db", "Wholesale Supabase project (real estate)", ["WHOLESALE_SUPABASE_URL", "WHOLESALE_SUPABASE_SERVICE_KEY"], [], ("monopoly",), True, "red", False),
    ("github", "GitHub (Jarvis dev pull requests)", ["GITHUB_TOKEN", "GITHUB_REPO"], ["GITHUB_BASE_BRANCH", "JARVIS_GITHUB_TOKEN"], ("fruition-factory",), True, "red", False),
    ("backup", "Encrypted off-site backup (Backblaze B2 via gateway)", ["BACKUP_PUT_URL", "BACKUP_AUTH", "BACKUP_KEY"], ["BACKUP_READER_JWT", "BACKUP_GATEWAY_APIKEY"], ALL, True, "red", False),
    ("whatsapp", "WhatsApp Business (owner alerts, off by default)", ["WHATSAPP_ACCESS_TOKEN", "WHATSAPP_PHONE_NUMBER_ID", "WHATSAPP_OWNER_NUMBER"], ["JARVIS_WHATSAPP", "WHATSAPP_TEMPLATE"], ALL, True, "yellow", False),
    ("emergency_call", "Twilio emergency call to the owner (off by default)", ["TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM_NUMBER", "OWNER_PHONE_NUMBER"], ["JARVIS_EMERGENCY_CALL"], ALL, True, "yellow", False),
    ("rbc", "RBC bank (manual: statement CSV via /bank, no credential ever)", [], [], ALL, True, "red", False),
    ("stripe", "Stripe client invoicing (drafts; sends only with the owner's approval; off until FZ_STRIPE_INVOICING=1)", ["STRIPE_SECRET_KEY"], ["FZ_STRIPE_INVOICING", "FZ_STRIPE_LIVE"], ("donna",), True, "red", False),
    ("meta_ads", "Meta Ads API (paid campaigns)", [], [], ("ff-marketing",), False, "red", False),
    ("elevenlabs", "ElevenLabs voice", [], [], ("b2b-records", "pimp-ai"), False, "yellow", False),
    ("gmail", "Gmail inbox reading", [], [], ("donna", "wolf-squad"), False, "yellow", False),
    ("google_drive", "Google Drive files", [], [], ("fruition-factory",), False, "yellow", False),
    ("airtable", "Airtable bases", [], [], ("donna",), False, "yellow", False),
]
KEYS = tuple(i[0] for i in INTEGRATIONS)
MANUAL = {"rbc"}
AUTO = {"railway"}


def _set(env, name):
    return bool(str(env.get(name) or "").strip())


def state(item, env=None):
    """-> dict with names and a state. Values are never read beyond 'is it non-empty'."""
    env = os.environ if env is None else env
    key, name, req, opt, offices, code, tier, core = item
    have = [n for n in req if _set(env, n)]
    opt_have = [n for n in opt if _set(env, n)]
    if not code:
        st = "not-built"
    elif key in MANUAL:
        st = "manual"
    elif key in AUTO:
        st = "auto" if opt_have else "missing"
    elif not req:
        st = "present" if opt_have else "missing"
    elif len(have) == len(req):
        st = "present"
    elif have:
        st = "partial"
    else:
        st = "missing"
    return {"key": key, "name": name, "state": st, "tier": tier, "core": core, "offices": list(offices),
            "missing": [n for n in req if n not in have], "optional_set": opt_have, "optional_missing": [n for n in opt if n not in opt_have]}


def report(office=None, env=None):
    if office and office not in ALL:
        raise SystemExit(f"unknown office {office!r}; one of: {', '.join(ALL)}")
    return [state(i, env) for i in INTEGRATIONS if not office or office in i[4]]


def text(rows):
    out = []
    for r in rows:
        line = f"{r['state']:<10} {r['key']:<15} [{r['tier']}{', core' if r['core'] else ''}] {r['name']}"
        if r["missing"] and r["state"] in ("partial", "missing"):
            line += "  -- not set: " + ", ".join(r["missing"])
        out.append(line)
    n = {s: sum(1 for r in rows if r["state"] == s) for s in ("present", "partial", "missing")}
    out.append(f"\n{n['present']} present, {n['partial']} partial, {n['missing']} missing (env var names only; values are never read or printed)")
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--office")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--strict", action="store_true")
    a = ap.parse_args(argv)
    rows = report(a.office)
    print(json.dumps(rows, indent=1) if a.json else text(rows))
    if a.strict and any(r["core"] and r["state"] != "present" for r in rows):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
