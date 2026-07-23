"""
Telegram <-> Claude bridge bot.

Reads your Telegram bot token and Anthropic API key from environment
variables (loaded from a local .env file - see .env.example). Never
edit this file to add secrets.
"""

import asyncio
import logging
import os
import re
import sqlite3
import time
from pathlib import Path

from anthropic import Anthropic, APIError
from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ResultMessage,
    SystemMessage,
    TextBlock,
    ToolUseBlock,
    query,
)
from claude_agent_sdk.types import PermissionResultAllow, PermissionResultDeny
from dotenv import load_dotenv
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ChatAction
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

load_dotenv()

TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN")
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY")
CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "claude-opus-4-8")
SYSTEM_PROMPT = os.environ.get(
    "SYSTEM_PROMPT", "You are a helpful assistant, chatting with the user over Telegram."
)

# Only this Telegram user id may use /build - find yours via @userinfobot.
JARVIS_OWNER_ID = os.environ.get("JARVIS_OWNER_ID")

# Where /build reads and writes files. Defaults to a folder that sits next to
# (not inside) this bot's own repo, so it never touches the bot's own code.
WORKSPACE_DIR = Path(
    os.environ.get(
        "WORKSPACE_DIR", str(Path(__file__).resolve().parent.parent / "jarvis-projects")
    )
).resolve()

MAX_TURNS = 20  # how many past messages (user+assistant) to keep per chat
TELEGRAM_MESSAGE_LIMIT = 4096
DB_PATH = os.environ.get("DB_PATH", "conversations.db")

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s", level=logging.INFO
)
logger = logging.getLogger(__name__)

anthropic_client = Anthropic(api_key=ANTHROPIC_API_KEY)


def init_db() -> None:
    """Create the conversation history table if it doesn't exist yet."""
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id INTEGER NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_messages_chat_id ON messages (chat_id, id)"
        )


def load_history(chat_id: int) -> list[dict]:
    """Load this chat's saved conversation, oldest message first."""
    with sqlite3.connect(DB_PATH) as conn:
        rows = conn.execute(
            "SELECT role, content FROM messages WHERE chat_id = ? ORDER BY id ASC",
            (chat_id,),
        ).fetchall()
    return [{"role": role, "content": content} for role, content in rows]


def save_message(chat_id: int, role: str, content: str) -> None:
    """Persist one message and trim old ones beyond MAX_TURNS for this chat."""
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            "INSERT INTO messages (chat_id, role, content) VALUES (?, ?, ?)",
            (chat_id, role, content),
        )
        conn.execute(
            """
            DELETE FROM messages
            WHERE chat_id = ? AND id NOT IN (
                SELECT id FROM messages WHERE chat_id = ? ORDER BY id DESC LIMIT ?
            )
            """,
            (chat_id, chat_id, MAX_TURNS),
        )


def clear_history(chat_id: int) -> None:
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("DELETE FROM messages WHERE chat_id = ?", (chat_id,))


# In-memory state for the /build feature, keyed by Telegram chat id.
# Ephemeral by design - if the bot restarts mid-build, just run /build again.
build_sessions: dict[int, dict] = {}

# Bash commands /build will always refuse, even after you've approved a plan.
# This is a best-effort denylist, not a hard sandbox - see the README.
BASH_HARD_BLOCKS = (
    "git push",
    "git remote",
    "sudo ",
    "rm -rf /",
    "mkfs",
    "shutdown",
    "reboot",
    "chmod -r 777 /",
    "> /dev/sd",
    ":(){ :|:& };:",
)

# Matches the `gh` CLI as its own command word (start of string, or after a
# shell separator) so it doesn't false-positive on ordinary words like "high".
GH_CLI_PATTERN = re.compile(r"(^|[;&|]\s*)gh\s")


def _is_dangerous_bash(command: str) -> tuple[bool, str]:
    lowered = command.lower()
    for phrase in BASH_HARD_BLOCKS:
        if phrase in lowered:
            return True, f"contains '{phrase.strip()}'"
    if GH_CLI_PATTERN.search(lowered):
        return True, "uses the GitHub CLI (gh)"
    piping_to_shell = any(p in lowered for p in ("| sh", "|sh", "| bash", "|bash"))
    if ("curl" in lowered or "wget" in lowered) and piping_to_shell:
        return True, "downloads and pipes into a shell"
    return False, ""


def _resolve_within_workspace(path_str: str) -> Path | None:
    """Return the resolved path if it's inside WORKSPACE_DIR, else None."""
    candidate = Path(path_str)
    if not candidate.is_absolute():
        candidate = WORKSPACE_DIR / candidate
    try:
        resolved = candidate.resolve()
    except OSError:
        return None
    if resolved == WORKSPACE_DIR or WORKSPACE_DIR in resolved.parents:
        return resolved
    return None


def _snapshot_workspace() -> dict[str, float]:
    """Map every file currently under WORKSPACE_DIR to its last-modified time.

    Used to detect what actually changed on disk during a build, instead of
    trusting the model's tool calls (a requested write may have been denied,
    resolved somewhere other than WORKSPACE_DIR, or simply failed).
    """
    snapshot: dict[str, float] = {}
    if WORKSPACE_DIR.exists():
        for path in WORKSPACE_DIR.rglob("*"):
            if path.is_file():
                snapshot[str(path.relative_to(WORKSPACE_DIR))] = path.stat().st_mtime
    return snapshot


async def build_permission_gate(tool_name, input_data, context):
    """can_use_tool callback for the build phase - the actual safety boundary.

    Runs on every Write/Edit/Bash call once a build is approved and enforces:
    file writes must stay inside WORKSPACE_DIR, and Bash can't push to GitHub,
    run as root, or pipe a download into a shell.
    """
    if tool_name in ("Write", "Edit", "NotebookEdit"):
        file_path = input_data.get("file_path", "")
        if _resolve_within_workspace(file_path) is None:
            return PermissionResultDeny(
                message=(
                    f"'{file_path}' is outside the allowed workspace, so I can't "
                    f"write there. Use an absolute path starting with exactly "
                    f"'{WORKSPACE_DIR}' for every file you create or edit - for "
                    f"example '{WORKSPACE_DIR}/hello.py', not a bare relative "
                    "filename or a path anywhere else."
                )
            )
        return PermissionResultAllow(updated_input=input_data)

    if tool_name == "Bash":
        command = str(input_data.get("command", ""))
        dangerous, reason = _is_dangerous_bash(command)
        if dangerous:
            return PermissionResultDeny(
                message=f"That command is blocked ({reason}). Try a different approach."
            )
        return PermissionResultAllow(updated_input=input_data)

    return PermissionResultAllow(updated_input=input_data)


def split_for_telegram(text: str) -> list[str]:
    """Telegram rejects messages over 4096 characters - split long replies."""
    if len(text) <= TELEGRAM_MESSAGE_LIMIT:
        return [text]
    chunks = []
    while text:
        chunks.append(text[:TELEGRAM_MESSAGE_LIMIT])
        text = text[TELEGRAM_MESSAGE_LIMIT:]
    return chunks


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    clear_history(update.effective_chat.id)
    await update.message.reply_text(
        "Hi! I'm connected to Claude. Send me a message and I'll reply.\n"
        "Our conversation is saved, so I'll still remember it if you restart me.\n"
        "Use /reset to clear our conversation history."
    )


async def reset(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    clear_history(update.effective_chat.id)
    await update.message.reply_text("Conversation history cleared.")


async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    chat_id = update.effective_chat.id
    user_text = update.message.text

    history = load_history(chat_id)
    history.append({"role": "user", "content": user_text})

    await context.bot.send_chat_action(chat_id=chat_id, action=ChatAction.TYPING)

    try:
        response = anthropic_client.messages.create(
            model=CLAUDE_MODEL,
            max_tokens=2048,
            system=SYSTEM_PROMPT,
            messages=history,
        )
    except APIError as e:
        logger.exception("Anthropic API error")
        await update.message.reply_text(
            f"Sorry, I hit an error talking to Claude: {e.message}"
        )
        return  # don't persist the failed turn

    reply_text = "".join(
        block.text for block in response.content if block.type == "text"
    )
    if not reply_text:
        reply_text = "(Claude returned no text - it may have refused this request.)"

    save_message(chat_id, "user", user_text)
    save_message(chat_id, "assistant", reply_text)

    for chunk in split_for_telegram(reply_text):
        await update.message.reply_text(chunk)


def _is_owner(user_id: int) -> bool:
    return bool(JARVIS_OWNER_ID) and str(user_id) == str(JARVIS_OWNER_ID)


async def build(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    chat_id = update.effective_chat.id

    if not _is_owner(update.effective_user.id):
        await update.message.reply_text(
            "The /build feature isn't enabled for you. Set JARVIS_OWNER_ID in "
            ".env to your Telegram user id to enable it."
        )
        return

    if chat_id in build_sessions:
        await update.message.reply_text(
            "I'm already working on something in this chat. Send /cancelbuild "
            "to stop it first."
        )
        return

    task_text = " ".join(context.args) if context.args else ""
    if not task_text:
        await update.message.reply_text("Usage: /build <what you want me to build>")
        return

    WORKSPACE_DIR.mkdir(parents=True, exist_ok=True)
    build_sessions[chat_id] = {"status": "planning", "task": task_text, "session_id": None}

    await update.message.reply_text(
        "🔎 Looking into it - I'll only plan for now, no changes yet..."
    )
    asyncio.create_task(run_plan_phase(chat_id, context, task_text))


async def cancel_build(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    chat_id = update.effective_chat.id
    if not _is_owner(update.effective_user.id):
        return
    if build_sessions.pop(chat_id, None):
        await update.message.reply_text("Okay, stopped.")
    else:
        await update.message.reply_text("Nothing is running right now.")


async def run_plan_phase(
    chat_id: int, context: ContextTypes.DEFAULT_TYPE, task_text: str
) -> None:
    session_id = None
    plan_text_parts: list[str] = []

    plan_prompt = (
        f"{task_text}\n\n"
        f"Your workspace is {WORKSPACE_DIR} - explore it as needed. When you "
        f"describe files you'd create or change, always give the full path "
        f"starting with {WORKSPACE_DIR} (e.g. {WORKSPACE_DIR}/hello.py), never "
        "a bare filename or a path outside this directory. Propose a concrete, "
        "specific plan for how you'd build this. Do not write or edit any "
        "files or run any commands yet - just explain what you'd create or "
        "change, and why."
    )

    try:
        async for message in query(
            prompt=plan_prompt,
            options=ClaudeAgentOptions(
                cwd=str(WORKSPACE_DIR),
                permission_mode="plan",
                allowed_tools=["Read", "Grep", "Glob", "WebSearch", "WebFetch"],
                disallowed_tools=["Write", "Edit", "Bash", "NotebookEdit", "AskUserQuestion"],
            ),
        ):
            if isinstance(message, SystemMessage) and message.subtype == "init":
                session_id = message.data.get("session_id")
            elif isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        plan_text_parts.append(block.text)
            elif isinstance(message, ResultMessage) and message.subtype != "success":
                logger.error("Plan phase failed: %s", message.error_code)
    except Exception:
        logger.exception("Plan phase crashed")
        build_sessions.pop(chat_id, None)
        await context.bot.send_message(
            chat_id, "Sorry, I hit an error while planning. Try /build again."
        )
        return

    state = build_sessions.get(chat_id)
    if state is None:  # /cancelbuild was sent while we were working
        return

    plan_text = "\n".join(plan_text_parts).strip() or "(No plan text returned.)"
    state["status"] = "awaiting_approval"
    state["session_id"] = session_id

    for chunk in split_for_telegram(plan_text):
        await context.bot.send_message(chat_id, chunk)

    keyboard = InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton(
                    "✅ Build it", callback_data=f"build:approve:{chat_id}"
                ),
                InlineKeyboardButton(
                    "❌ Cancel", callback_data=f"build:cancel:{chat_id}"
                ),
            ]
        ]
    )
    await context.bot.send_message(
        chat_id, "Want me to go ahead and build this?", reply_markup=keyboard
    )


async def build_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query_cb = update.callback_query
    await query_cb.answer()

    if not _is_owner(query_cb.from_user.id):
        return

    _, action, chat_id_str = query_cb.data.split(":")
    chat_id = int(chat_id_str)

    state = build_sessions.get(chat_id)
    if not state or state.get("status") != "awaiting_approval":
        await query_cb.edit_message_text("This request is no longer active.")
        return

    if action == "cancel":
        build_sessions.pop(chat_id, None)
        await query_cb.edit_message_text("Cancelled - no changes were made.")
        return

    state["status"] = "building"
    await query_cb.edit_message_text("🛠 Building now...")
    asyncio.create_task(run_build_phase(chat_id, context, state))


async def run_build_phase(
    chat_id: int, context: ContextTypes.DEFAULT_TYPE, state: dict
) -> None:
    status_message = await context.bot.send_message(chat_id, "Starting...")
    last_edit = 0.0

    async def update_status(text: str) -> None:
        nonlocal last_edit
        now = time.monotonic()
        if now - last_edit < 2 and not text.startswith(("✅", "⚠️")):
            return
        last_edit = now
        try:
            await status_message.edit_text(text[:TELEGRAM_MESSAGE_LIMIT])
        except Exception:
            pass  # text unchanged or rate-limited - not worth failing over

    result_summary = None
    final_text_parts: list[str] = []
    build_prompt = (
        "Go ahead and build the plan you just proposed. Create and edit every "
        f"file using its full absolute path starting with exactly "
        f"{WORKSPACE_DIR} (e.g. {WORKSPACE_DIR}/hello.py) - never a bare "
        "relative filename, and never a path outside this directory."
    )

    WORKSPACE_DIR.mkdir(parents=True, exist_ok=True)
    before_snapshot = _snapshot_workspace()

    # The module-level query() function ties the whole session to the
    # lifetime of its input: with a can_use_tool callback, if the prompt
    # generator finishes before a tool call is fully permitted and executed,
    # the connection those permission decisions travel over can close
    # mid-flight ("AbortError: Stream closed"). ClaudeSDKClient decouples
    # sending the prompt from consuming the response, keeping the session
    # open for the whole turn - which is what a can_use_tool callback needs.
    try:
        async with ClaudeSDKClient(
            options=ClaudeAgentOptions(
                cwd=str(WORKSPACE_DIR),
                resume=state["session_id"],
                permission_mode="default",
                disallowed_tools=["AskUserQuestion"],
                can_use_tool=build_permission_gate,
            )
        ) as client:
            await client.query(build_prompt)
            async for message in client.receive_response():
                if isinstance(message, AssistantMessage):
                    for block in message.content:
                        if isinstance(block, ToolUseBlock):
                            # These are what Claude *requested* - just for a
                            # live progress ping. Whether they actually
                            # landed on disk is checked afterwards via
                            # before/after_snapshot, since a request can be
                            # denied or fail silently.
                            if block.name in ("Write", "Edit", "NotebookEdit"):
                                file_path = block.input.get("file_path")
                                await update_status(f"✏️ Editing {file_path}")
                            elif block.name == "Bash":
                                command = str(block.input.get("command", ""))[:200]
                                await update_status(f"⚙️ Running: {command}")
                            else:
                                await update_status(f"🔍 Using {block.name}...")
                        elif isinstance(block, TextBlock):
                            final_text_parts.append(block.text)
                elif isinstance(message, ResultMessage):
                    result_summary = message
    except Exception:
        logger.exception("Build phase crashed")
        build_sessions.pop(chat_id, None)
        await context.bot.send_message(
            chat_id, "Something went wrong while building. Check the logs."
        )
        return

    build_sessions.pop(chat_id, None)

    # Ground truth: what actually changed on disk, not what was requested.
    after_snapshot = _snapshot_workspace()
    created = sorted(after_snapshot.keys() - before_snapshot.keys())
    modified = sorted(
        p for p in (after_snapshot.keys() & before_snapshot.keys())
        if after_snapshot[p] != before_snapshot[p]
    )
    final_text = "\n".join(final_text_parts).strip()

    if not created and not modified:
        message_text = (
            "⚠️ Claude finished, but I couldn't find any new or changed files "
            f"in {WORKSPACE_DIR}. It may have tried writing outside the "
            "workspace (which I block) or hit an error. Here's what it said:\n\n"
            f"{final_text or '(no explanation given)'}"
        )
        await update_status(message_text[:TELEGRAM_MESSAGE_LIMIT])
        if len(message_text) > TELEGRAM_MESSAGE_LIMIT:
            for chunk in split_for_telegram(message_text[TELEGRAM_MESSAGE_LIMIT:]):
                await context.bot.send_message(chat_id, chunk)
        return

    changes = [f"- created {p}" for p in created] + [f"- modified {p}" for p in modified]
    files_list = "\n".join(changes)
    cost = (
        f"${result_summary.total_cost_usd:.2f}"
        if result_summary and result_summary.total_cost_usd
        else "n/a"
    )
    status_prefix = "✅ Done." if (result_summary and result_summary.subtype == "success") else (
        f"⚠️ Finished with an error ({result_summary.error_code if result_summary else 'unknown'}), "
        "but some files did change:"
    )
    await update_status(
        f"{status_prefix}\n\nChanges in {WORKSPACE_DIR}:\n{files_list}\n\nCost: {cost}\n\n"
        "Review it and commit/push yourself when you're happy with it."
    )


def main() -> None:
    if not TELEGRAM_BOT_TOKEN:
        raise SystemExit(
            "TELEGRAM_BOT_TOKEN is not set. Put it in a .env file - see .env.example."
        )
    if not ANTHROPIC_API_KEY:
        raise SystemExit(
            "ANTHROPIC_API_KEY is not set. Put it in a .env file - see .env.example."
        )

    init_db()

    if not JARVIS_OWNER_ID:
        logger.warning(
            "JARVIS_OWNER_ID is not set - /build is disabled until you add your "
            "Telegram user id to .env. Chat still works normally."
        )

    app = Application.builder().token(TELEGRAM_BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("reset", reset))
    app.add_handler(CommandHandler("build", build))
    app.add_handler(CommandHandler("cancelbuild", cancel_build))
    app.add_handler(CallbackQueryHandler(build_callback, pattern=r"^build:"))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))

    logger.info("Bot starting (model=%s)...", CLAUDE_MODEL)
    app.run_polling()


if __name__ == "__main__":
    main()
