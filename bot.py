"""
Telegram <-> Claude bridge bot.

Reads your Telegram bot token and Anthropic API key from environment
variables (loaded from a local .env file - see .env.example). Never
edit this file to add secrets.
"""

import asyncio
import itertools
import json
import logging
import os
import re
import sqlite3
import time
import urllib.error
import urllib.request
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

# Webhook Jarvis calls when you ask it to kick off your Make.com scenario.
MAKE_WEBHOOK_URL = os.environ.get("MAKE_WEBHOOK_URL")

# Self-hosted n8n instance Jarvis can build and trigger workflows in.
N8N_BASE_URL = os.environ.get("N8N_BASE_URL", "").rstrip("/")
N8N_API_KEY = os.environ.get("N8N_API_KEY")

# How long an approval request waits for a yes/no tap before giving up.
APPROVAL_TIMEOUT_SECONDS = 300

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


def init_n8n_registry() -> None:
    """Create the local table that maps workflow names to n8n ids/webhooks.

    n8n itself is the source of truth for workflow content; this table just
    lets Jarvis look a workflow up by the plain-English name the user used,
    without having to search n8n every time.
    """
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS n8n_workflows (
                name TEXT PRIMARY KEY,
                workflow_id TEXT NOT NULL,
                webhook_path TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
            """
        )


def save_n8n_workflow(name: str, workflow_id: str, webhook_path: str | None) -> None:
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            "INSERT OR REPLACE INTO n8n_workflows (name, workflow_id, webhook_path) "
            "VALUES (?, ?, ?)",
            (name, workflow_id, webhook_path),
        )


def get_n8n_workflow(name: str) -> tuple[str, str | None] | None:
    """Case-insensitive lookup of a previously-registered workflow by name."""
    with sqlite3.connect(DB_PATH) as conn:
        row = conn.execute(
            "SELECT workflow_id, webhook_path FROM n8n_workflows "
            "WHERE name = ? COLLATE NOCASE",
            (name,),
        ).fetchone()
    return row


# In-memory state for the /build feature, keyed by Telegram chat id.
# Ephemeral by design - if the bot restarts mid-build, just run /build again.
build_sessions: dict[int, dict] = {}

# Pending yes/no approval requests (e.g. before building/activating/triggering
# an n8n workflow), keyed by a short request id. Ephemeral by design - if the
# bot restarts while a request is outstanding, it's simply lost and whatever
# was waiting on it will report a denial/timeout.
pending_approvals: dict[str, asyncio.Future] = {}
_approval_id_counter = itertools.count()


async def request_approval(
    context: ContextTypes.DEFAULT_TYPE,
    chat_id: int,
    description: str,
    timeout: float = APPROVAL_TIMEOUT_SECONDS,
) -> bool:
    """Ask the owner to approve an action on Telegram and wait for their tap.

    This is the safety boundary for every build/activate/trigger action Jarvis
    can take in n8n: nothing happens until this returns True. Returns False on
    an explicit deny, a timeout, or if the button is never pressed.
    """
    request_id = f"{chat_id}-{next(_approval_id_counter)}"
    future: asyncio.Future = asyncio.get_running_loop().create_future()
    pending_approvals[request_id] = future

    keyboard = InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("✅ Approve", callback_data=f"approve:yes:{request_id}"),
                InlineKeyboardButton("❌ Deny", callback_data=f"approve:no:{request_id}"),
            ]
        ]
    )
    await context.bot.send_message(chat_id, description, reply_markup=keyboard)

    try:
        return await asyncio.wait_for(future, timeout=timeout)
    except asyncio.TimeoutError:
        return False
    finally:
        pending_approvals.pop(request_id, None)


async def approval_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query_cb = update.callback_query
    try:
        await query_cb.answer()
    except Exception:
        # A stale/expired callback_query_id makes Telegram reject the ack
        # with a 400. That's cosmetic - don't let it stop us from actually
        # resolving the approval below.
        logger.warning("answerCallbackQuery failed (likely expired query id); continuing anyway")

    if not _is_owner(query_cb.from_user.id):
        return

    _, decision, request_id = query_cb.data.split(":", 2)
    future = pending_approvals.get(request_id)
    if future is None or future.done():
        await query_cb.edit_message_text("This request is no longer active.")
        return

    approved = decision == "yes"
    future.set_result(approved)
    await query_cb.edit_message_text("✅ Approved." if approved else "❌ Denied.")


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


# Claude decides when to call this based on the description below - no need
# to match an exact phrase like "kick off my Make scenario".
MAKE_SCENARIO_TOOL = {
    "name": "trigger_make_scenario",
    "description": (
        "Trigger the user's Make.com automation scenario by calling its "
        "webhook. Use this whenever the user asks to kick off, run, trigger, "
        "or start their Make.com scenario, automation, or workflow."
    ),
    "input_schema": {"type": "object", "properties": {}},
}


def _should_offer_make_tool(user_id: int) -> bool:
    # Gated the same way as /build - anyone who messages the bot shouldn't
    # be able to trigger a real automation in your business.
    return bool(MAKE_WEBHOOK_URL) and _is_owner(user_id)


async def trigger_make_webhook() -> str:
    """POST to MAKE_WEBHOOK_URL. Returns a short status string for Claude."""
    if not MAKE_WEBHOOK_URL:
        return "The Make.com webhook isn't configured - MAKE_WEBHOOK_URL is missing from .env."

    def _post() -> str:
        req = urllib.request.Request(
            MAKE_WEBHOOK_URL,
            data=b"{}",
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            return f"Webhook responded with HTTP {resp.status}."

    try:
        result = await asyncio.to_thread(_post)
        logger.info("Triggered Make.com webhook: %s", result)
        return result
    except urllib.error.HTTPError as e:
        logger.error("Make.com webhook returned an error: %s", e)
        return f"Webhook call failed with HTTP {e.code}."
    except Exception as e:
        logger.exception("Make.com webhook call failed")
        return f"Webhook call failed: {e}"


# --- n8n integration -------------------------------------------------------
#
# Claude decides when to call these based on their descriptions below. Every
# build/activate/trigger action goes through request_approval() first - see
# handle_build_n8n_workflow / handle_trigger_n8n_workflow.

BUILD_N8N_WORKFLOW_TOOL = {
    "name": "build_n8n_workflow",
    "description": (
        "Create and activate a brand-new workflow in the user's self-hosted "
        "n8n instance. Use this when the user asks you to build, create, or "
        "set up a new automation/workflow in n8n. You must construct the "
        "complete n8n workflow JSON yourself: a JSON object with a 'nodes' "
        "array and a 'connections' object, following n8n's node-based "
        "workflow schema (each node needs at minimum id, name, type, "
        "typeVersion, position, and parameters). The workflow MUST include "
        "exactly one Webhook trigger node (type 'n8n-nodes-base.webhook') "
        "with a short unique 'path' (e.g. a slug of the workflow name), so "
        "it can be triggered later with trigger_n8n_workflow. If the user "
        "wants this workflow to run on a recurring schedule (e.g. daily, "
        "hourly), also add a Schedule Trigger node (type "
        "'n8n-nodes-base.scheduleTrigger') configured with that cadence, in "
        "addition to the Webhook node. This tool will NOT run until the "
        "user approves it on Telegram - the result you get back tells you "
        "whether it was approved and whether it succeeded. Do not tell the "
        "user the workflow exists until you see a success result."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "name": {
                "type": "string",
                "description": "Short, human-readable workflow name.",
            },
            "workflow_json": {
                "type": "string",
                "description": (
                    "The complete n8n workflow definition as a JSON string "
                    "(a JSON object with 'nodes' and 'connections' keys)."
                ),
            },
            "summary": {
                "type": "string",
                "description": (
                    "One or two plain-English sentences describing what this "
                    "workflow does and what happens when it runs, shown to "
                    "the user in the Telegram approval prompt."
                ),
            },
        },
        "required": ["name", "workflow_json", "summary"],
    },
}

TRIGGER_N8N_WORKFLOW_TOOL = {
    "name": "trigger_n8n_workflow",
    "description": (
        "Immediately run an existing n8n workflow by name, via its webhook "
        "trigger. Use this when the user asks to run, trigger, kick off, or "
        "test a workflow that already exists in n8n - not for building a new "
        "one. This tool will NOT run until the user approves it on Telegram."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "name": {
                "type": "string",
                "description": "The workflow's name, as created or listed.",
            }
        },
        "required": ["name"],
    },
}

LIST_N8N_WORKFLOWS_TOOL = {
    "name": "list_n8n_workflows",
    "description": (
        "List workflows that exist in the user's n8n instance, and whether "
        "each is active. Read-only - use this freely when the user asks "
        "what workflows exist or wants a status check; it does not require "
        "approval."
    ),
    "input_schema": {"type": "object", "properties": {}},
}


def _should_offer_n8n_tools(user_id: int) -> bool:
    # Same reasoning as the Make.com tool: only the owner can build/trigger
    # real automations, and only once n8n is actually configured.
    return bool(N8N_BASE_URL) and bool(N8N_API_KEY) and _is_owner(user_id)


def _n8n_request(method: str, path: str, body: dict | None = None) -> dict:
    """Blocking helper - always call via asyncio.to_thread."""
    url = f"{N8N_BASE_URL}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "X-N8N-API-KEY": N8N_API_KEY or "",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


async def n8n_create_workflow(name: str, workflow_json: dict) -> dict:
    body = {
        "name": name,
        "nodes": workflow_json["nodes"],
        "connections": workflow_json["connections"],
        "settings": workflow_json.get("settings", {}),
    }
    return await asyncio.to_thread(_n8n_request, "POST", "/api/v1/workflows", body)


async def n8n_activate_workflow(workflow_id: str) -> dict:
    return await asyncio.to_thread(
        _n8n_request, "POST", f"/api/v1/workflows/{workflow_id}/activate"
    )


async def n8n_get_workflow(workflow_id: str) -> dict:
    return await asyncio.to_thread(_n8n_request, "GET", f"/api/v1/workflows/{workflow_id}")


async def n8n_list_workflows() -> list[dict]:
    result = await asyncio.to_thread(_n8n_request, "GET", "/api/v1/workflows")
    return result.get("data", [])


def _extract_webhook_path(workflow_json: dict) -> str | None:
    for node in workflow_json.get("nodes", []):
        if node.get("type") == "n8n-nodes-base.webhook":
            return node.get("parameters", {}).get("path")
    return None


async def trigger_webhook_path(path: str) -> str:
    url = f"{N8N_BASE_URL}/webhook/{path.lstrip('/')}"

    def _post() -> int:
        req = urllib.request.Request(
            url, data=b"{}", method="POST", headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status

    status = await asyncio.to_thread(_post)
    return f"Webhook responded with HTTP {status}."


async def handle_build_n8n_workflow(
    tool_input: dict, context: ContextTypes.DEFAULT_TYPE, chat_id: int
) -> str:
    name = tool_input.get("name") or "Untitled workflow"
    summary = tool_input.get("summary", "").strip()
    raw_json = tool_input.get("workflow_json", "")

    try:
        workflow_json = json.loads(raw_json)
    except (json.JSONDecodeError, TypeError) as e:
        return f"Couldn't parse the workflow JSON: {e}. Fix it and try again."

    if not isinstance(workflow_json, dict) or "nodes" not in workflow_json or "connections" not in workflow_json:
        return "The workflow JSON must be an object with 'nodes' and 'connections' keys."

    description = (
        f"🔧 Build n8n workflow: {name}\n\n"
        f"{summary or '(no description given)'}\n\n"
        "This will create it in n8n and activate it. Approve?"
    )
    if not await request_approval(context, chat_id, description):
        return "DENIED: the user did not approve this. Do not create the workflow or tell the user it exists."

    try:
        created = await n8n_create_workflow(name, workflow_json)
        workflow_id = created.get("id")
        if not workflow_id:
            return f"n8n did not return a workflow id. Raw response: {created}"

        await n8n_activate_workflow(workflow_id)
        webhook_path = _extract_webhook_path(workflow_json)
        save_n8n_workflow(name, workflow_id, webhook_path)

        result = f"SUCCESS: created and activated '{name}' (n8n id {workflow_id})."
        if webhook_path:
            result += f" It can be triggered via trigger_n8n_workflow(name='{name}')."
        else:
            result += " It has no Webhook node, so it can't be triggered on demand."
        return result
    except Exception as e:
        logger.exception("Failed to build n8n workflow")
        return f"FAILED: could not create/activate the workflow in n8n: {e}"


async def handle_trigger_n8n_workflow(
    tool_input: dict, context: ContextTypes.DEFAULT_TYPE, chat_id: int
) -> str:
    name = (tool_input.get("name") or "").strip()
    if not name:
        return "No workflow name was given."

    display_name = name
    webhook_path = None
    row = get_n8n_workflow(name)

    if row:
        _, webhook_path = row
    else:
        # Not built through Jarvis (or the local registry was wiped) - fall
        # back to asking n8n directly.
        try:
            workflows = await n8n_list_workflows()
        except Exception as e:
            return f"Couldn't reach n8n to look up '{name}': {e}"
        match = next(
            (w for w in workflows if w.get("name", "").strip().lower() == name.lower()), None
        )
        if not match:
            return f"No workflow called '{name}' was found. Use list_n8n_workflows to see what exists."
        display_name = match.get("name", name)
        try:
            detail = await n8n_get_workflow(match["id"])
            webhook_path = _extract_webhook_path(detail)
            save_n8n_workflow(display_name, match["id"], webhook_path)
        except Exception:
            logger.exception("Failed to fetch workflow detail from n8n")

    if not webhook_path:
        return f"'{display_name}' has no Webhook trigger node, so it can't be triggered on demand."

    description = f"▶️ Trigger n8n workflow: {display_name}\n\nApprove?"
    if not await request_approval(context, chat_id, description):
        return "DENIED: the user did not approve this. Do not trigger the workflow."

    try:
        result = await trigger_webhook_path(webhook_path)
        return f"SUCCESS: triggered '{display_name}'. {result}"
    except Exception as e:
        logger.exception("Failed to trigger n8n workflow")
        return f"FAILED: could not trigger '{display_name}': {e}"


async def handle_list_n8n_workflows() -> str:
    try:
        workflows = await n8n_list_workflows()
    except Exception as e:
        return f"Couldn't reach n8n: {e}"
    if not workflows:
        return "There are no workflows in n8n yet."
    lines = [
        f"- {w.get('name')} ({'active' if w.get('active') else 'inactive'})"
        for w in workflows
    ]
    return "Workflows in n8n:\n" + "\n".join(lines)


async def dispatch_tool_call(
    tool_name: str, tool_input: dict, context: ContextTypes.DEFAULT_TYPE, chat_id: int
) -> str:
    if tool_name == "trigger_make_scenario":
        return await trigger_make_webhook()
    if tool_name == "build_n8n_workflow":
        return await handle_build_n8n_workflow(tool_input, context, chat_id)
    if tool_name == "trigger_n8n_workflow":
        return await handle_trigger_n8n_workflow(tool_input, context, chat_id)
    if tool_name == "list_n8n_workflows":
        return await handle_list_n8n_workflows()
    return f"Unknown tool: {tool_name}"


async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    chat_id = update.effective_chat.id
    user_text = update.message.text

    history = load_history(chat_id)
    messages = history + [{"role": "user", "content": user_text}]

    await context.bot.send_chat_action(chat_id=chat_id, action=ChatAction.TYPING)

    tools = []
    if _should_offer_make_tool(update.effective_user.id):
        tools.append(MAKE_SCENARIO_TOOL)
    if _should_offer_n8n_tools(update.effective_user.id):
        tools.extend([BUILD_N8N_WORKFLOW_TOOL, TRIGGER_N8N_WORKFLOW_TOOL, LIST_N8N_WORKFLOWS_TOOL])
    kwargs = {"tools": tools} if tools else {}

    # Cap on tool round-trips per user message, so a confused model can't
    # loop forever - five is generous for e.g. "build this, then trigger it".
    MAX_TOOL_ROUNDS = 5

    try:
        response = anthropic_client.messages.create(
            model=CLAUDE_MODEL,
            max_tokens=2048,
            system=SYSTEM_PROMPT,
            messages=messages,
            **kwargs,
        )

        for _ in range(MAX_TOOL_ROUNDS):
            if response.stop_reason != "tool_use":
                break

            assistant_content = response.content
            tool_results = []
            for block in assistant_content:
                if block.type != "tool_use":
                    continue
                await context.bot.send_chat_action(chat_id=chat_id, action=ChatAction.TYPING)
                result_text = await dispatch_tool_call(block.name, block.input, context, chat_id)
                tool_results.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": result_text,
                    }
                )

            messages = messages + [
                {"role": "assistant", "content": assistant_content},
                {"role": "user", "content": tool_results},
            ]
            response = anthropic_client.messages.create(
                model=CLAUDE_MODEL,
                max_tokens=2048,
                system=SYSTEM_PROMPT,
                messages=messages,
                **kwargs,
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
    init_n8n_registry()

    if not (N8N_BASE_URL and N8N_API_KEY):
        logger.warning(
            "N8N_BASE_URL/N8N_API_KEY not set - n8n build/trigger tools are "
            "disabled until both are added to Railway's Variables."
        )

    if not JARVIS_OWNER_ID:
        logger.warning(
            "JARVIS_OWNER_ID is not set - /build is disabled until you add your "
            "Telegram user id to .env. Chat still works normally."
        )

    # concurrent_updates is required for the approval gate: while
    # request_approval() is awaiting a button tap inside one update's
    # handler, the bot must still be able to process the callback_query
    # update from that very tap. Without this, python-telegram-bot handles
    # updates one at a time and the two deadlock until the approval times out.
    app = Application.builder().token(TELEGRAM_BOT_TOKEN).concurrent_updates(True).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("reset", reset))
    app.add_handler(CommandHandler("build", build))
    app.add_handler(CommandHandler("cancelbuild", cancel_build))
    app.add_handler(CallbackQueryHandler(build_callback, pattern=r"^build:"))
    app.add_handler(CallbackQueryHandler(approval_callback, pattern=r"^approve:"))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))

    logger.info("Bot starting (model=%s)...", CLAUDE_MODEL)
    app.run_polling()


if __name__ == "__main__":
    main()
