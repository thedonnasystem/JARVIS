"""
Telegram <-> Claude bridge bot.

Reads your Telegram bot token and Anthropic API key from environment
variables (loaded from a local .env file - see .env.example). Never
edit this file to add secrets.
"""

import logging
import os

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

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s", level=logging.INFO
)
logger = logging.getLogger(__name__)

anthropic_client = Anthropic(api_key=ANTHROPIC_API_KEY)

# Very simple in-memory conversation history, keyed by Telegram chat id.
# This resets whenever the bot process restarts.
conversations: dict[int, list[dict]] = {}


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
    conversations.pop(update.effective_chat.id, None)
    await update.message.reply_text(
        "Hi! I'm connected to Claude. Send me a message and I'll reply.\n"
        "Use /reset to clear our conversation history."
    )


async def reset(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    conversations.pop(update.effective_chat.id, None)
    await update.message.reply_text("Conversation history cleared.")


async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    chat_id = update.effective_chat.id
    user_text = update.message.text

    history = conversations.setdefault(chat_id, [])
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
        history.pop()  # don't keep the failed turn in history
        return

    reply_text = "".join(
        block.text for block in response.content if block.type == "text"
    )
    if not reply_text:
        reply_text = "(Claude returned no text - it may have refused this request.)"

    history.append({"role": "assistant", "content": reply_text})
    # Keep history from growing without bound.
    del history[:-MAX_TURNS]

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

    app = Application.builder().token(TELEGRAM_BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("reset", reset))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))

    logger.info("Bot starting (model=%s)...", CLAUDE_MODEL)
    app.run_polling()


if __name__ == "__main__":
    main()
