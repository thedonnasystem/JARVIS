"""Telegram commands for the legacy offices (owner only, read-only):
  /doctor <office>|all [plan]   technical health, plain diagnosis, ranked fixes; 'plan' adds a free-brain improvement plan (redacted structure only)
  /qc <office>|all              outcome funnel, quality rubric, bottleneck, keep / fix / kill, top 3 changes by revenue impact
Wiring is one try-block in hq_commands.register (a locked file): docs/proposals/legacy_offices.md. Until the owner approves that change these
commands are not registered; `python3 -m legacy_offices.cli` gives the same output.
"""
from __future__ import annotations

import asyncio
import logging
import os

from legacy_offices import doctor, qc, registry

logger = logging.getLogger(__name__)
USAGE_DOCTOR = "Usage: /doctor <office>|all [plan]. Offices: " + ", ".join(registry.slugs(False))
USAGE_QC = "Usage: /qc <office>|all. Offices: " + ", ".join(registry.slugs(False))


def _owner(update) -> bool:
    owner = os.environ.get("JARVIS_OWNER_ID")
    return bool(owner) and str(getattr(update.effective_user, "id", "")) == str(owner)


def doctor_text(args: list[str], **kw) -> str:
    if not args:
        return USAGE_DOCTOR
    if args[0].lower() == "all":
        return doctor.all_text([doctor.examine(s, **kw) for s in registry.slugs(False)])
    slug = registry.resolve(args[0])
    if not slug:
        return USAGE_DOCTOR
    rep = doctor.examine(slug, **kw)
    out = doctor.text(rep)
    if len(args) > 1 and args[1].lower() == "plan" and rep.get("findings"):
        out += "\n\nImprovement plan (draft):\n" + doctor.plan(slug, rep)
    return out


def qc_text(args: list[str], **kw) -> str:
    if not args:
        return USAGE_QC
    state_path = os.environ.get("LEGACY_QC_STATE") or None
    state = qc.load_state(state_path)
    if args[0].lower() == "all":
        reps = [qc.review(s, state=state, **kw) for s in registry.slugs(False)]
        qc.save_state(state_path, reps)
        return qc.all_text(reps)
    slug = registry.resolve(args[0])
    if not slug:
        return USAGE_QC
    rep = qc.review(slug, state=state, **kw)
    qc.save_state(state_path, [rep])
    return qc.text(rep)


async def _reply(update, text: str) -> None:
    import hq_core
    await hq_core.reply_to(update.message, text[:4000])


async def doctor_cmd(update, context) -> None:
    if not _owner(update):
        return
    try:
        text = await asyncio.to_thread(doctor_text, list(getattr(context, "args", None) or []))
    except Exception as e:
        logger.exception("office doctor failed")
        text = f"Doctor failed: {type(e).__name__}"
    await _reply(update, text)


async def qc_cmd(update, context) -> None:
    if not _owner(update):
        return
    try:
        text = await asyncio.to_thread(qc_text, list(getattr(context, "args", None) or []))
    except Exception as e:
        logger.exception("office qc failed")
        text = f"QC failed: {type(e).__name__}"
    await _reply(update, text)


def register(app, CommandHandler) -> None:
    app.add_handler(CommandHandler("doctor", doctor_cmd))
    app.add_handler(CommandHandler("qc", qc_cmd))
