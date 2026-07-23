"""
Telegram <-> Claude bridge bot.

Reads your Telegram bot token and Anthropic API key from environment
variables (loaded from a local .env file - see .env.example). Never
edit this file to add secrets.
"""

import logging
import os
import sqlite3

from anthropic import Anthropic, APIError
from dotenv import load_dotenv
from telegram import Update
from telegram.constants import ChatAction
from telegram.ext import (
    Application,
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

    app = Application.builder().token(TELEGRAM_BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("reset", reset))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))

    logger.info("Bot starting (model=%s)...", CLAUDE_MODEL)
    app.run_polling()


if __name__ == "__main__":
    main()
